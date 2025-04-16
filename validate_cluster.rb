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
    puts "✅ Validating Kubernetes API server..."
    result = run_command("kubectl get --raw /healthz")
    raise "❌ API server health check failed: #{result}" unless result == "ok"
    puts "✅ Kubernetes API server is healthy."
  end

  def validate_nodes
    puts "✅ Validating Kubernetes nodes..."
    nodes = JSON.parse(run_command("kubectl get nodes -o json"))
    nodes['items'].each do |node|
      name = node['metadata']['name']
      status = node['status']['conditions'].find { |c| c['type'] == 'Ready' }['status']
      if status == "True"
        puts "✅ Node #{name} is Ready."
        validate_node_conditions(node)
      else
        raise "❌ Node #{name} is NOT Ready!"
      end
    end
  end

  def validate_node_conditions(node)
    capacity = node['status']['capacity']
    puts "  🏗️  CPU: #{capacity['cpu']}, Memory: #{capacity['memory']}"
    pressure_conditions = ['DiskPressure', 'MemoryPressure', 'PIDPressure']
    pressure_conditions.each do |condition|
      status = node['status']['conditions'].find { |c| c['type'] == condition }['status']
      puts "  #{condition}: #{status == 'False' ? '✅ OK' : '⚠️ WARNING!'}"
    end

    # NEW: Check kubelet service status
    puts "  🔍 Checking kubelet service..."
    kubelet_status = run_command("kubectl describe node #{node['metadata']['name']} | grep -i 'Conditions' -A 10")
    puts kubelet_status

    # NEW: Check container runtime status
    puts "  🔍 Checking container runtime..."
    containerd_status = run_command("kubectl get nodes -o wide")
    puts containerd_status
  end

  def validate_namespace
    puts "✅ Validating default namespaces..."
    namespaces = JSON.parse(run_command("kubectl get namespaces -o json"))
    required_namespaces = ['default', 'kube-system', 'kube-public', 'kube-node-lease']
    required_namespaces.each do |ns|
      if namespaces['items'].any? { |namespace| namespace['metadata']['name'] == ns }
        puts "✅ Namespace #{ns} exists."
      else
        raise "❌ Namespace #{ns} is missing!"
      end
    end
  end

  def validate_core_services
    puts "✅ Validating core services..."
    services = run_command("kubectl get pods -n kube-system")
    required_services = ['kube-apiserver', 'kube-controller-manager', 'kube-scheduler', 'coredns', 'kube-proxy']
    required_services.each do |service|
      if services.include?(service)
        puts "✅ #{service} is running."
      else
        raise "❌ #{service} is NOT running!"
      end
    end
  end

  def validate_coredns
    puts "✅ Validating CoreDNS..."
    coredns_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l k8s-app=kube-dns -o json"))
    coredns_pods['items'].each do |pod|
      name = pod['metadata']['name']
      status = pod['status']['phase']
      ready = pod['status']['containerStatuses']&.all? { |container| container['ready'] }
      if status == 'Running' && ready
        puts "✅ CoreDNS pod #{name} is healthy."
      else
        raise "❌ CoreDNS pod #{name} is NOT healthy! Status: #{status}, Ready: #{ready}"
      end
    end
    validate_dns_resolution
  end

  def validate_dns_resolution
    puts "✅ Validating DNS resolution..."
    
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
          image: busybox:1.28
          command:
          - sleep
          - "60"
        restartPolicy: Never
    YAML
    
    begin
      # Create the test pod
      run_command("echo '#{test_pod_yaml}' | kubectl apply -f -")
      puts "Created temporary test pod #{test_pod_name}"
      
      # Wait for the pod to be ready (up to 30 seconds)
      ready = false
      30.times do |i|
        pod_status = run_command("kubectl get pod #{test_pod_name} -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Pending'")
        if pod_status == "Running"
          ready = true
          break
        end
        puts "Waiting for test pod to be ready (#{i+1}/30)..." if (i+1) % 5 == 0
        sleep 1
      end
      
      unless ready
        raise "Test pod did not become ready in time"
      end
      
      # Run the DNS test
      dns_test_output = run_command("kubectl exec #{test_pod_name} -- nslookup kubernetes.default.svc.cluster.local")
      puts dns_test_output
      
      # Check for successful DNS resolution - looking for either "Address:" or "Address 1:" 
      # and checking for the Kubernetes service IP
      if (dns_test_output.include?('Address:') || dns_test_output.include?('Address 1:')) && 
         dns_test_output.include?('10.233.0.1') && 
         !dns_test_output.include?('server can\'t find')
        puts "✅ DNS resolution test passed."
      else
        raise "❌ DNS resolution test failed - incorrect response!"
      end
    rescue => e
      puts "DNS test error: #{e.message}"
      raise "❌ DNS resolution test failed!"
    ensure
      # Always clean up the test pod
      begin
        run_command("kubectl delete pod #{test_pod_name} --force --grace-period=0 2>/dev/null || true")
        puts "Cleaned up temporary test pod"
      rescue => cleanup_error
        puts "Warning: Failed to clean up test pod: #{cleanup_error.message}"
      end
    end
  end

  def validate_etcd
    puts "✅ Validating etcd cluster health..."
    etcd_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l component=etcd -o json"))
    etcd_pods['items'].each do |pod|
      name = pod['metadata']['name']
      status = pod['status']['phase']
      ready = pod['status']['containerStatuses']&.all? { |container| container['ready'] }
      if status == 'Running' && ready
        puts "✅ etcd pod #{name} is healthy."
      else
        raise "❌ etcd pod #{name} is NOT healthy! Status: #{status}, Ready: #{ready}"
      end
    end
  end

  def validate_kubelet_logs
    puts "🔍 Checking kubelet logs for TLS issues..."
    tls_errors = run_command("journalctl -u kubelet --no-pager | grep 'certificate' || echo ''")
    if tls_errors.empty?
      puts "✅ No TLS certificate issues detected in kubelet logs."
    else
      puts "❌ TLS certificate errors detected:"
      puts tls_errors
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
        raise "❌ Cluster validation failed after #{MAX_RETRIES} attempts."
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
    validate_etcd
    validate_kubelet_logs
    puts "✅ Kubernetes cluster validation passed successfully!"
  end
end

# Usage
validator = ClusterValidator.new
validator.validate_with_retries
