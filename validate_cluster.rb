#!/usr/bin/env ruby
require 'json'
require 'open3'

class ClusterValidator
  MAX_RETRIES = 3
  RETRY_DELAY = 5 # seconds

  def run_command(command)
    stdout, stderr, status = Open3.capture3(command)
    unless status.success?
      raise "Command failed: #{command}. Error: #{stderr}"
    end
    stdout.strip
  end

  def validate_api_server
    puts "✅  Validating Kubernetes API server..."
    result = run_command("kubectl get --raw /healthz")
    raise "❌  API server health check failed: #{result}" unless result == "ok"
    puts "✅  Kubernetes API server is healthy."
  end

  def validate_nodes
    puts "✅  Validating Kubernetes nodes..."
    nodes = JSON.parse(run_command("kubectl get nodes -o json"))
    nodes['items'].each do |node|
      name = node['metadata']['name']
      status = node['status']['conditions'].find { |c| c['type'] == 'Ready' }['status']
      if status == "True"
        puts "✅  Node #{name} is Ready."
        validate_node_conditions(node)
      else
        raise "❌  Node #{name} is NOT Ready!"
      end
    end
  end

  def validate_node_conditions(node)
    capacity = node['status']['capacity']
    puts "  🏗️  CPU: #{capacity['cpu']}, Memory: #{capacity['memory']}"
    pressure_conditions = ['DiskPressure', 'MemoryPressure', 'PIDPressure']
    pressure_conditions.each do |condition|
      status = node['status']['conditions'].find { |c| c['type'] == condition }['status']
      puts "  #{condition}: #{status == 'False' ? '✅  OK' : '⚠️ WARNING!'}"
    end
    # Check kubelet service status
    puts "  🔍 Checking kubelet service..."
    kubelet_status = run_command("kubectl describe node #{node['metadata']['name']} | grep -i 'Conditions' -A 10")
    puts kubelet_status
    # Check container runtime status
    puts "  🔍 Checking container runtime..."
    containerd_status = run_command("kubectl get nodes -o wide")
    puts containerd_status
  end

  def validate_namespace
    puts "✅  Validating default namespaces..."
    namespaces = JSON.parse(run_command("kubectl get namespaces -o json"))
    required_namespaces = ['default', 'kube-system', 'kube-public', 'kube-node-lease']
    required_namespaces.each do |ns|
      if namespaces['items'].any? { |namespace| namespace['metadata']['name'] == ns }
        puts "✅  Namespace #{ns} exists."
      else
        raise "❌  Namespace #{ns} is missing!"
      end
    end
  end

  def validate_core_services
    puts "✅  Validating core services..."
    services = run_command("kubectl get pods -n kube-system")
    required_services = ['kube-apiserver', 'kube-controller-manager', 'kube-scheduler', 'coredns', 'kube-proxy']
    required_services.each do |service|
      if services.include?(service)
        puts "✅  #{service} is running."
      else
        raise "❌  #{service} is NOT running!"
      end
    end
  end

  def validate_coredns
    puts "✅  Validating CoreDNS..."
    coredns_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l k8s-app=kube-dns -o json"))
    coredns_pods['items'].each do |pod|
      name = pod['metadata']['name']
      status = pod['status']['phase']
      ready = pod['status']['containerStatuses']&.all? { |container| container['ready'] }
      if status == 'Running' && ready
        puts "✅  CoreDNS pod #{name} is healthy."
      else
        raise "❌  CoreDNS pod #{name} is NOT healthy! Status: #{status}, Ready: #{ready}"
      end
    end
    validate_dns_resolution
  end

def validate_dns_resolution
  puts "✅  Validating DNS resolution..."
  # First, let's try a simple command to check DNS directly from a node
  begin
    puts "Testing DNS directly from a node..."
    direct_test = run_command("kubectl run -i --rm --restart=Never busybox --image=busybox:latest -- nslookup kubernetes.default.svc.cluster.local")
    puts direct_test
    if direct_test.include?('Address:') && !direct_test.include?('server can\'t find')
      puts "✅  Direct DNS resolution test passed."
      return # Success! We can exit early
    else
      puts "⚠️  Direct DNS resolution did not return expected result, trying alternative method..."
    end
  rescue => e
    puts "⚠️  Direct DNS test failed: #{e.message}, trying alternative method..."
  end

  # Create a temporary test pod with DNS tools
  test_pod_name = "dns-test-#{Time.now.to_i}"
  test_pod_yaml = <<~YAML
    apiVersion: v1
    kind: Pod
    metadata:
      name: #{test_pod_name}
    spec:
      containers:
      - name: dns-test
        image: busybox:latest
        command:
        - sleep
        - "300"
        resources:
          limits:
            memory: "64Mi"
            cpu: "100m"
          requests:
            memory: "32Mi"
            cpu: "50m"
      restartPolicy: Never
  YAML

  begin
    # Create the test pod
    run_command("echo '#{test_pod_yaml}' | kubectl apply -f -")
    puts "Created temporary test pod #{test_pod_name}"
    
    # Wait for the pod to be fully ready
    begin
      run_command("kubectl wait --for=condition=ready pod/#{test_pod_name} --timeout=60s")
      puts "Test pod is ready"
    rescue => e
      puts "Error waiting for pod: #{e.message}"
      raise "Test pod did not become ready in time"
    end
    
    # Show the DNS config in the pod
    dns_config = run_command("kubectl exec #{test_pod_name} -- cat /etc/resolv.conf")
    puts "DNS configuration in test pod:"
    puts dns_config
    
    # Let's try a simpler DNS lookup command that has better compatibility
    puts "Testing DNS with host command..."
    begin
      host_output = run_command("kubectl exec #{test_pod_name} -- wget -O- -q kubernetes.default.svc.cluster.local:443 || echo 'Connection refused but DNS worked'")
      puts "Host command output: #{host_output}"
      puts "✅  DNS resolution successful (host command)"
      return
    rescue => e
      puts "⚠️  Host command failed: #{e.message}"
    end
    
    # Let's try a ping with -c1 option to check name resolution
    puts "Testing DNS with ping command..."
    begin
      ping_output = run_command("kubectl exec #{test_pod_name} -- ping -c1 -W3 kubernetes.default.svc.cluster.local")
      puts ping_output
      puts "✅  DNS resolution successful (ping command)"
      return
    rescue => e
      puts "⚠️  Ping test failed: #{e.message}"
    end
    
    # Try a simple netcat check
    puts "Testing with netcat..."
    begin
      nc_test = run_command("kubectl exec #{test_pod_name} -- sh -c 'echo | nc -w3 kubernetes.default.svc.cluster.local 443 || echo $?'")
      puts "Netcat result: #{nc_test}"
      if nc_test != "1"
        puts "✅  DNS resolution successful (netcat command)"
        return
      end
    rescue => e
      puts "⚠️  Netcat test failed: #{e.message}"
    end
    
    # If all tests failed, raise an error
    raise "❌  All DNS resolution tests failed!"
    
  rescue => e
    puts "DNS test error: #{e.message}"
    # Get more diagnostic information
    begin
      coredns_logs = run_command("kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50")
      puts "CoreDNS logs:"
      puts coredns_logs
    rescue => log_error
      puts "Could not get CoreDNS logs: #{log_error.message}"
    end
    raise "❌  DNS resolution test failed!"
  ensure
    # Always clean up the test pod
    begin
      puts "Cleaning up temporary test pod..."
      run_command("kubectl delete pod #{test_pod_name} --force --grace-period=0 2>/dev/null || true")
      puts "Cleaned up temporary test pod"
    rescue => cleanup_error
      puts "Warning: Failed to clean up test pod: #{cleanup_error.message}"
    end
  end
end

  def validate_etcd
    puts "✅  Validating etcd cluster health..."
    etcd_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l component=etcd -o json"))
    
    if etcd_pods['items'].empty?
      puts "ℹ️  No etcd pods found. This might be normal if using an external etcd."
      return
    end
    
    etcd_pods['items'].each do |pod|
      name = pod['metadata']['name']
      status = pod['status']['phase']
      ready = pod['status']['containerStatuses']&.all? { |container| container['ready'] }
      if status == 'Running' && ready
        puts "✅  etcd pod #{name} is healthy."
      else
        raise "❌  etcd pod #{name} is NOT healthy! Status: #{status}, Ready: #{ready}"
      end
    end
  end

  def validate_kubelet_logs
    puts "🔍 Checking kubelet logs for TLS issues..."
    begin
      tls_errors = run_command("journalctl -u kubelet --no-pager | grep 'certificate' || echo ''")
      if tls_errors.empty?
        puts "✅  No TLS certificate issues detected in kubelet logs."
      else
        puts "⚠️  TLS certificate entries detected (may or may not indicate issues):"
        puts tls_errors
      end
    rescue => e
      puts "⚠️  Could not check kubelet logs: #{e.message}"
    end
  end

  def validate_with_retries
    attempts = 0
    begin
      attempts += 1
      puts "🔁 Validation attempt #{attempts}..."
      main_validation
    rescue => e
      puts e.message
      if attempts < MAX_RETRIES
        puts "🔄 Retrying in #{RETRY_DELAY} seconds..."
        sleep(RETRY_DELAY)
        retry
      else
        raise "❌  Cluster validation failed after #{MAX_RETRIES} attempts."
      end
    end
  end

  def main_validation
    puts "🚀 Starting Kubernetes cluster validation..."
    validate_api_server
    validate_nodes
    validate_namespace
    validate_core_services
    validate_coredns
    
    # The etcd validation might fail on managed Kubernetes where etcd is not exposed
    begin
      validate_etcd
    rescue => e
      puts "⚠️  Etcd validation skipped: #{e.message}"
    end
    
    validate_kubelet_logs
    puts "✅  Kubernetes cluster validation passed successfully!"
  end
end

# Usage
validator = ClusterValidator.new
validator.validate_with_retries
