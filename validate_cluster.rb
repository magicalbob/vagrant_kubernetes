# validate_cluster.rb
require 'json'
require 'open3'

# Helper to run shell commands
def run_command(command)
  stdout, stderr, status = Open3.capture3(command)
  unless status.success?
    puts "Command failed: #{command}"
    puts "Error: #{stderr}"
    exit 1
  end
  stdout.strip
end

# Validate the Kubernetes API server
def validate_api_server
  puts "Validating Kubernetes API server..."
  result = run_command("kubectl get --raw /healthz")
  if result == "ok"
    puts "Kubernetes API server is healthy."
  else
    puts "API server health check failed: #{result}"
    exit 1
  end
end

# Validate the nodes in the cluster
def validate_nodes
  puts "Validating Kubernetes nodes..."
  nodes = JSON.parse(run_command("kubectl get nodes -o json"))
  nodes['items'].each do |node|
    name = node['metadata']['name']
    status = node['status']['conditions'].find { |c| c['type'] == 'Ready' }['status']
    if status == "True"
      puts "Node #{name} is Ready."
      
      # Check node capacity and allocatable resources
      capacity = node['status']['capacity']
      puts "  CPU: #{capacity['cpu']}, Memory: #{capacity['memory']}"
      
      # Check node pressure conditions
      pressure_conditions = ['DiskPressure', 'MemoryPressure', 'PIDPressure']
      pressure_conditions.each do |condition|
        status = node['status']['conditions'].find { |c| c['type'] == condition }['status']
        puts "  #{condition}: #{status == 'False' ? 'OK' : 'Warning!'}"
      end
    else
      puts "Node #{name} is not Ready!"
      exit 1
    end
  end
end

# Validate the default namespace
def validate_namespace
  puts "Validating default namespace..."
  namespaces = JSON.parse(run_command("kubectl get namespaces -o json"))
  required_namespaces = ['default', 'kube-system', 'kube-public', 'kube-node-lease']
  required_namespaces.each do |ns|
    if namespaces['items'].any? { |namespace| namespace['metadata']['name'] == ns }
      puts "#{ns} namespace exists."
    else
      puts "#{ns} namespace is missing!"
      exit 1
    end
  end
end

# Validate core services
def validate_core_services
  puts "Validating core services..."
  services = run_command("kubectl get pods -n kube-system")
  required_services = [
    'kube-apiserver',
    'kube-controller-manager',
    'kube-scheduler',
    'coredns',
    'kube-proxy'
  ]
  
  required_services.each do |service|
    if services.include?(service)
      puts "#{service} is running."
    else
      puts "#{service} is not running!"
      exit 1
    end
  end
end

# Validate CoreDNS
def validate_coredns
  puts "Validating CoreDNS..."
  begin
    coredns_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l k8s-app=kube-dns -o json"))
    coredns_pods['items'].each do |pod|
      name = pod['metadata']['name']
      status = pod['status']['phase']
      ready = pod['status']['containerStatuses']&.all? { |container| container['ready'] }
      
      if status == 'Running' && ready
        puts "CoreDNS pod #{name} is healthy."
      else
        puts "CoreDNS pod #{name} is not healthy! Status: #{status}, Ready: #{ready}"
        exit 1
      end
    end
    
    # Test DNS resolution
    test_pod_yaml = <<~YAML
      apiVersion: v1
      kind: Pod
      metadata:
        name: dns-test
      spec:
        containers:
        - name: dns-test
          image: busybox:1.28
          command: ['sh', '-c', 'nslookup kubernetes.default.svc.cluster.local']
    YAML
    
    run_command("echo '#{test_pod_yaml}' | kubectl apply -f -")
    sleep 10  # Wait for pod to complete
    dns_test_output = run_command("kubectl logs dns-test")
    run_command("kubectl delete pod dns-test")
    
    if dns_test_output.include?('kubernetes.default.svc.cluster.local')
      puts "DNS resolution test passed."
    else
      puts "DNS resolution test failed!"
      exit 1
    end
  rescue => e
    puts "CoreDNS validation failed: #{e.message}"
    exit 1
  end
end

# Validate network connectivity
def validate_network
  puts "Validating network connectivity..."
  begin
    # Check if network plugin is running
    network_pods = run_command("kubectl get pods -A -o wide | grep -E 'calico|flannel|weave|cilium'")
    puts "Network plugin pods found: #{network_pods}"
    
    # Test pod-to-pod communication
    test_pods_yaml = <<~YAML
      apiVersion: v1
      kind: Pod
      metadata:
        name: network-test-1
      spec:
        containers:
        - name: network-test
          image: busybox:1.28
          command: ['sleep', '3600']
      ---
      apiVersion: v1
      kind: Pod
      metadata:
        name: network-test-2
      spec:
        containers:
        - name: network-test
          image: busybox:1.28
          command: ['sleep', '3600']
    YAML
    
    run_command("echo '#{test_pods_yaml}' | kubectl apply -f -")
    sleep 10  # Wait for pods to start
    
    # Test connectivity between pods
    run_command("kubectl exec network-test-1 -- ping -c 1 network-test-2")
    puts "Pod-to-pod communication test passed."
    
    # Cleanup test pods
    run_command("kubectl delete pod network-test-1 network-test-2")
  rescue => e
    puts "Network validation failed: #{e.message}"
    exit 1
  end
end

# Validate ETCD health
def validate_etcd
  puts "Validating etcd cluster health..."
  begin
    etcd_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l component=etcd -o json"))
    etcd_pods['items'].each do |pod|
      name = pod['metadata']['name']
      status = pod['status']['phase']
      ready = pod['status']['containerStatuses']&.all? { |container| container['ready'] }
      
      if status == 'Running' && ready
        puts "etcd pod #{name} is healthy."
      else
        puts "etcd pod #{name} is not healthy! Status: #{status}, Ready: #{ready}"
        exit 1
      end
    end
  rescue => e
    puts "etcd validation failed: #{e.message}"
    exit 1
  end
end

# Main validation routine
def main
  puts "Starting Kubernetes cluster validation..."
  validate_api_server
  validate_nodes
  validate_namespace
  validate_core_services
  validate_coredns
  validate_network
  validate_etcd
  puts "Kubernetes cluster validation passed successfully!"
end

# Run the main routine
main
