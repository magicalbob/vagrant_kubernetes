#!/usr/bin/env python3

from diagrams import Diagram, Cluster, Edge
from diagrams.generic.storage import Storage
from diagrams.onprem.compute import Server
from diagrams.generic.network import Firewall
from diagrams.programming.language import Bash
from IPython.display import Image

CHART_NAME = "Lower_Level"

with Diagram("Vagrant Host", show=False, filename=CHART_NAME):
    with Cluster("Vagrant_Kubernetes_Setup.sh"):
        config_json = Storage("config.json")
        read_config = Bash("Read config.json")
        vagrant_template = Storage("Vagrantfile.template")
        make_vagrant_file = Bash("Make Vagrantfile\nfrom template")
        vagrant_file = Storage("Vagrantfile")
        vagrant_up = Bash("vagrant up\n(with loop to make sure\nall are up)")
        vagrant_provision = Bash("vagrant provision")
        generate_hosts_yaml = Bash("Generate the\nhosts.yaml content")
        clone_kubespray = Bash("Clone the project\nto do the actual\nkubernetes cluster\nsetup (kubespray)")
        execute_kubespray = Bash("Execute kubespray")

    config_json >> read_config >> make_vagrant_file >> vagrant_file
    vagrant_template >> make_vagrant_file
    vagrant_file >> vagrant_up >> vagrant_provision >> generate_hosts_yaml >> clone_kubespray
    clone_kubespray >> execute_kubespray

Image(filename=f"{CHART_NAME}.png")
