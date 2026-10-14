# CJ SketchUp MCP

MCP maps Codex tools to the Ruby API inside one or more running SketchUp instances. It uses Python's standard library and the project-local file queue; it opens no network ports.

## Install

Register the MCP server once in Codex (the existing `sketchup-cj` entry points to this file):

```powershell
codex mcp add sketchup-cj -- 'C:\Users\Golyatin.av\AppData\Local\Programs\Python\Python310\python.exe' 'C:\Users\Golyatin.av\Documents\ChatGPT\Skethcup инсоляция\tooling\mcp\server.py'
```

For automatic bridge startup in every SketchUp 2022 instance, run:

```powershell
.\tooling\install_bridge.ps1 -SketchUpVersion 2022
```

Restart each SketchUp instance. Each process gets a separate session and request folder. In the project developer setup, the `CJ` toolbar includes `Подключить CJ Bridge`: it starts a stopped bridge or reports the PID when already connected. The `Extensions → CJ Bridge` menu also provides restart, stop, and status commands.

## Tools

Geometry capture and example workflow: [EXAMPLES.md](../EXAMPLES.md). The current server has 18 tools, including `sketchup_capture_model`, `sketchup_capture_view`, and `sketchup_export_model`. Model tools accept `expected_model_token` from status to reject commands after the active document changes. These tools create runtime artifacts without saving the SKP.

The SketchUp connection panel also has an MCP section: launch a background handshake and a read-only model status query, show the tool count, and copy local launch settings for Codex. This checks a separate diagnostic MCP client, not the running Codex client. Codex owns its stdio server process; enable, disable, and restart that connection in Codex. The panel never rewrites Codex configuration. The current panel launcher uses the installed per-user Python 3.10 runtime and reports an error if it is absent.

Call `sketchup_list_instances` first. Then pass its `instance_id` to each model tool. The result includes PID, SketchUp version, model title/path and heartbeat freshness.

| Tool | Purpose |
|---|---|
| `sketchup_status`, `sketchup_inspect_model` | Connection and model summary |
| `sketchup_list_entities` | Find objects by type, name or tag; returns persistent IDs |
| `sketchup_get_selection`, `sketchup_set_selection` | Read or set selection |
| `sketchup_raycast` | Query first visible geometry hit; coordinates in mm |
| `sketchup_create_geometry` | Create a line or face in a new group |
| `sketchup_edit_entity` | Change name, visibility, tag or material |
| `sketchup_move_entities`, `sketchup_delete_entities` | Edit objects by persistent ID |
| `sketchup_save_model` | Save the target model to its existing file |
| `sketchup_reload_plugin`, `sketchup_run_checks`, `sketchup_run_geometry_tests` | CJ development and geometry checks |

Edits use SketchUp undo operations. Save and delete are marked destructive in MCP metadata. Arbitrary Ruby evaluation and shell execution are not exposed.

## Runtime and validation

Sessions live under `tooling/runtime/instances/<instance-id>/`. MCP checks session identity, heartbeat, command allowlists and request expiry before dispatch. A SketchUp Ruby timer handles one request per UI cycle; API calls stay on SketchUp's main thread. Large operations must be chunked if they need progress or cancellation.

Run protocol and multi-instance routing tests:

```powershell
python .\tooling\mcp\test_server.py
```

Run live checks in an idle SketchUp model after the bridge has loaded:

```powershell
python .\tooling\mcp\test_server.py --live
```

This live suite reads model state, runs the existing CJ checks and runs temporary geometry checks that roll back. It does not save the model. Use a throwaway model when testing create/edit/delete/save tools.

## Security and limits

The transport is local files, not localhost HTTP. Only listed commands execute; there is no `eval`. Keep the project folder private because a local process with access to it can enqueue requests. The selected instance must be running with its bridge timer responsive. A modal dialog or long synchronous plugin operation can delay requests. Commands do not intentionally bring the target SketchUp window to the foreground.

The Ruby API is only available inside SketchUp and must be called from its main thread. Some interface-only actions, such as interacting with arbitrary third-party dialogs, are outside this model API bridge.

## References

- [SketchUp Ruby API](https://ruby.sketchup.com/)
- [SketchUp UI timers and menus](https://ruby.sketchup.com/UI.html)
- [MCP tools and transports](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
