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
    puts "Validating Kubernetes API server..."
    result = run_command("kubectl get --raw /healthz")
    if result == "ok"
      puts "Kubernetes API server is healthy."
    else
      raise "API server health check failed: #{result}"
    end
  end

  def validate_nodes
    puts "Validating Kubernetes nodes..."
    nodes = JSON.parse(run_command("kubectl get nodes -o json"))
    nodes['items'].each do |node|
      name = node['metadata']['name']
      status = node['status']['conditions'].find { |c| c['type'] == 'Ready' }['status']
      if status == "True"
        puts "Node #{name} is Ready."
        validate_node_conditions(node)
      else
        raise "Node #{name} is not Ready!"
      end
    end
  end

  def validate_node_conditions(node)
    capacity = node['status']['capacity']
    puts "  CPU: #{capacity['cpu']}, Memory: #{capacity['memory']}"
    pressure_conditions = ['DiskPressure', 'MemoryPressure', 'PIDPressure']
    pressure_conditions.each do |condition|
      status = node['status']['conditions'].find { |c| c['type'] == condition }['status']
      puts "  #{condition}: #{status == 'False' ? 'OK' : 'Warning!'}"
    end
  end

  def validate_namespace
    puts "Validating default namespaces..."
    namespaces = JSON.parse(run_command("kubectl get namespaces -o json"))
    required_namespaces = ['default', 'kube-system', 'kube-public', 'kube-node-lease']
    required_namespaces.each do |ns|
      if namespaces['items'].any? { |namespace| namespace['metadata']['name'] == ns }
        puts "Namespace #{ns} exists."
      else
        raise "Namespace #{ns} is missing!"
      end
    end
  end

  def validate_core_services
    puts "Validating core services..."
    services = run_command("kubectl get pods -n kube-system")
    required_services = ['kube-apiserver', 'kube-controller-manager', 'kube-scheduler', 'coredns', 'kube-proxy']
    required_services.each do |service|
      if services.include?(service)
        puts "#{service} is running."
      else
        raise "#{service} is not running!"
      end
    end
  end

  def validate_coredns
    puts "Validating CoreDNS..."
    coredns_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l k8s-app=kube-dns -o json"))
    coredns_pods['items'].each do |pod|
      name = pod['metadata']['name']
      status = pod['status']['phase']
      ready = pod['status']['containerStatuses']&.all? { |container| container['ready'] }
      if status == 'Running' && ready
        puts "CoreDNS pod #{name} is healthy."
      else
        raise "CoreDNS pod #{name} is not healthy! Status: #{status}, Ready: #{ready}"
      end
    end
    validate_dns_resolution
  end

  def validate_dns_resolution
    puts "Validating DNS resolution..."
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
    sleep 10
    dns_test_output = run_command("kubectl logs dns-test")
    run_command("kubectl delete pod dns-test")
    unless dns_test_output.include?('kubernetes.default.svc.cluster.local')
      raise "DNS resolution test failed!"
    end
    puts "DNS resolution test passed."
  end

  def validate_etcd
    puts "Validating etcd cluster health..."
    etcd_pods = JSON.parse(run_command("kubectl get pods -n kube-system -l component=etcd -o json"))
    etcd_pods['items'].each do |pod|
      name = pod['metadata']['name']
      status = pod['status']['phase']
      ready = pod['status']['containerStatuses']&.all? { |container| container['ready'] }
      if status == 'Running' && ready
        puts "etcd pod #{name} is healthy."
      else
        raise "etcd pod #{name} is not healthy! Status: #{status}, Ready: #{ready}"
      end
    end
  end

  def validate_with_retries
    attempts = 0
    begin
      attempts += 1
      puts "Validation attempt #{attempts}..."
      main_validation
    rescue => e
      puts e.message
      if attempts < MAX_RETRIES
        puts "Retrying in #{RETRY_DELAY} seconds..."
        sleep(RETRY_DELAY)
        retry
      else
        raise "Cluster validation failed after #{MAX_RETRIES} attempts."
      end
    end
  end

  def main_validation
    puts "Starting Kubernetes cluster validation..."
    validate_api_server
    validate_nodes
    validate_namespace
    validate_core_services
    validate_coredns
    validate_etcd
    puts "Kubernetes cluster validation passed successfully!"
  end
end

# Usage
validator = ClusterValidator.new
validator.validate_with_retries
