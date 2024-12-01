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
  if namespaces['items'].any? { |ns| ns['metadata']['name'] == 'default' }
    puts "Default namespace exists."
  else
    puts "Default namespace is missing!"
    exit 1
  end
end

# Validate core services
def validate_core_services
  puts "Validating core services..."
  services = run_command("kubectl get pods -n kube-system")
  if services.include?("kube-apiserver") &&
     services.include?("kube-controller-manager") &&
     services.include?("kube-scheduler")
    puts "Core services are running."
  else
    puts "One or more core services are not running!"
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
  puts "Kubernetes cluster validation passed successfully!"
end

# Run the main routine
main
