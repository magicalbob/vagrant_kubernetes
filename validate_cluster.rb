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

# Helper to wait for a resource
def wait_for_resource(resource_type, resource_name, namespace = nil, condition = "Ready", timeout = "60s")
  ns_option = namespace ? "-n #{namespace}" : ""
  command = "kubectl wait #{ns_option} --for=condition=#{condition} #{resource_type}/#{resource_name} --timeout=#{timeout}"
  puts "Waiting for #{resource_type} #{resource_name} in namespace #{namespace || 'default'} to be #{condition}..."
  result = run_command(command)
  puts result
end

# Retry a command with exponential backoff
def retry_with_backoff(retries, base_delay, &block)
  attempt = 0
  begin
    attempt += 1
    yield
  rescue => e
    if attempt < retries
      delay = base_delay * (2**(attempt - 1))
      puts "Retrying in #{delay} seconds... (attempt #{attempt}/#{retries})"
      sleep(delay)
      retry
    else
      puts "Operation failed after #{retries} attempts: #{e.message}"
      exit 1
    end
  end
end

# Validate the Kubernetes API server
def validate_api_server
  puts "Validating Kubernetes API server..."
  retry_with_backoff(5, 5) do
    result = run_command("kubectl get --raw /healthz")
    if result == "ok"
      puts "Kubernetes API server is healthy."
    else
      raise "API server health check failed: #{result}"
    end
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
        condition_status = node['status']['conditions'].find { |c| c['type'] == condition }['status']
        puts "  #{condition}: #{condition_status == 'False' ? 'OK' : 'Warning!'}"
      end
    else
      puts "Node #{name} is not Ready!"
      exit 1
    end
  end
end

# Validate namespaces
def validate_namespace
  puts "Validating namespaces..."
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

# Wait for CoreDNS pods
def wait_for_coredns
  puts "Waiting for CoreDNS pods to be ready..."
  coredns_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l k8s-app=kube-dns -o json"))
  coredns_pods['items'].each do |pod|
    name = pod['metadata']['name']
    wait_for_resource("pod", name, "kube-system", "Ready", "120s")
  end
end

# Validate CoreDNS
def validate_coredns
  puts "Validating CoreDNS..."
  wait_for_coredns
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
  wait_for_resource("pod", "dns-test", nil, "Succeeded", "60s")
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

# Wait for ETCD pods
def wait_for_etcd
  puts "Waiting for etcd pods to be ready..."
  etcd_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l component=etcd -o json"))
  etcd_pods['items'].each do |pod|
    name = pod['metadata']['name']
    wait_for_resource("pod", name, "kube-system", "Ready", "120s")
  end
end

# Validate ETCD health
def validate_etcd
  puts "Validating etcd cluster health..."
  wait_for_etcd
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

# Main validation routine
def main
  puts "Starting Kubernetes cluster validation..."
  validate_api_server
  validate_nodes
  validate_namespace
  validate_core_services
  validate_coredns
  validate_etcd
  puts "Kubernetes cluster validation passed successfully!"
end

# Run the main routine
main
