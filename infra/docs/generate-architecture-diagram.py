#!/usr/bin/env python3
"""Generate the architecture diagram for akamai-workshop-platform.

Requires `pip install diagrams` and graphviz (`brew install graphviz` /
`apt install graphviz`). Produces an accurate Kubernetes diagram. Note: the
committed architecture.png may instead be a gpt-image render — running this
script overwrites it with the diagrams-rendered version.
"""

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
        ing = Ingress("Ingress (nginx)\nsNN.workshop.host · TLS")
        np = NetworkPolicy("NetworkPolicy\ndefault-deny\nworkspaces → gateway only")

        with Cluster("CPU Node Pool"):
            workspaces = [
                Pod("ws-01\ncode-server"),
                Pod("ws-02\ncode-server"),
                Pod("ws-N\ncode-server"),
            ]

        with Cluster("Inference (multi-model)"):
            gw = Service("agentgateway:8080\nClusterIP · API-key auth")
            with Cluster("GPU Node Pools (1 per model)"):
                vllm_a = StatefulSet("vllm-<modelA>\n:8000")
                vllm_b = StatefulSet("vllm-<modelB>\n:8000")

    students >> Edge(label="HTTPS / TLS") >> ing
    ing >> workspaces
    workspaces >> Edge(style="dashed", label="Authorization: Bearer") >> gw
    gw >> Edge(label="route by model field") >> vllm_a
    gw >> Edge(label="route by model field") >> vllm_b
