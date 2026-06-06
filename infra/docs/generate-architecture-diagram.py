#!/usr/bin/env python3
"""Generate the architecture diagram for akamai-workshop-platform."""

import os
os.chdir(os.path.dirname(os.path.abspath(__file__)))

from diagrams import Diagram, Cluster, Edge
from diagrams.k8s.compute import Pod, StatefulSet
from diagrams.k8s.network import Ingress, Service, NetworkPolicy
from diagrams.onprem.client import User

graph_attr = {
    "fontsize": "16",
    "fontname": "Helvetica",
    "bgcolor": "white",
    "pad": "0.6",
    "nodesep": "0.6",
    "ranksep": "0.9",
    "splines": "ortho",
}

with Diagram(
    "akamai-workshop-platform",
    filename="architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
):
    students = User("Students\n(browser)")

    with Cluster("Akamai LKE Cluster"):
        ing = Ingress("Ingress\nsNN.base-host")
        np = NetworkPolicy("NetworkPolicy\ndefault-deny\nworkspace → vLLM only")

        with Cluster("CPU Node Pool"):
            workspaces = [
                Pod("ws-01\ncode-server"),
                Pod("ws-02\ncode-server"),
                Pod("ws-N\ncode-server"),
            ]

        with Cluster("GPU Node Pool"):
            svc = Service("vllm:8000\nClusterIP")
            vllm = StatefulSet("vLLM\n(model inference)")

    students >> Edge(label="HTTPS") >> ing
    ing >> workspaces
    workspaces >> Edge(style="dashed", label="internal") >> svc >> vllm
