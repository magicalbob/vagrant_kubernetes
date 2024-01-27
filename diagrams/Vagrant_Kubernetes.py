#!/usr/bin/env python3

from diagrams import Diagram, Cluster, Edge
#from diagrams.generic.network import Storage
from diagrams.generic.storage import Storage
from diagrams.onprem.compute import Server
from diagrams.generic.network import Firewall
#from diagrams.generic.system import Generic
#from diagrams.onprem.programming import Script
from diagrams.programming.language import Bash
from IPython.display import Image

CHART_NAME = "k8s"

with Diagram("Vagrant Host", show=False, filename=CHART_NAME):
    with Cluster("Vagrant Kubernetes Setup"):
        config_json = Storage("config.json")
        vagrant_template = Storage("Vagrantfile.template")
        vagrant_script = Bash("Vagrant_Kubernetes_Setup.sh")
        vagrant_file = Storage("Vagrantfile")

    config_json  >> vagrant_script
    vagrant_template >> vagrant_script
    vagrant_script >> vagrant_file

Image(filename=f"{CHART_NAME}.png")
