# -*- coding: utf-8 -*-
"""Run this file using Rhino _RunPythonScript. MCP is not needed afterwards."""
import os
import sys
folder = os.path.dirname(os.path.abspath(__file__))
if folder not in sys.path:
    sys.path.insert(0, folder)
import panel
panel.show()
