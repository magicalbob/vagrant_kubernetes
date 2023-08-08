#!/usr/bin/env bash
vagrant upload ~/.vagrant.d/insecure_private_key /home/vagrant/.ssh/id_rsa node1
ssh-keygen -y -f ~/.vagrant.d/insecure_private_key > ./insecure_public_key
vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub node1
vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub node2
vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub node3
vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub node4
vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub node5
vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub node6
vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' node1
vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' node2
vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' node3
vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' node4
vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' node5
vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' node6
vagrant ssh -c 'echo uptime|ssh -o StrictHostKeyChecking=no 192.168.200.201' node1
vagrant ssh -c 'echo uptime|ssh -o StrictHostKeyChecking=no 192.168.200.202' node1
vagrant ssh -c 'echo uptime|ssh -o StrictHostKeyChecking=no 192.168.200.203' node1
vagrant ssh -c 'echo uptime|ssh -o StrictHostKeyChecking=no 192.168.200.204' node1
vagrant ssh -c 'echo uptime|ssh -o StrictHostKeyChecking=no 192.168.200.205' node1
vagrant ssh -c 'echo uptime|ssh -o StrictHostKeyChecking=no 192.168.200.206' node1
