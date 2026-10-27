-- Test fixture only. Never bundled, installed or enabled by the OS installer.
local app = {minWidth = 18, minHeight = 4}
function app.render(width, height, state, osApi)
    local outputs = osApi.getOutputs()
    if #outputs == 0 then
        return {"No outputs mapped.", "On the OS console:", "map test io_ID left white", "set test on"}
    end
    local lines = {"Touch a row to toggle"}
    for i = 1, math.min(#outputs, height - 1) do
        local output = outputs[i]
        lines[i + 1] = output.name .. ": " .. (output.value and "ON" or "OFF")
            .. (output.confirmed and "" or (output.online and " (pending)" or " (offline)"))
    end
    if state.lastError then lines[height] = "Error: " .. state.lastError end
    return lines
end
function app.handleTouch(x, y, width, height, state, osApi)
    local output = osApi.getOutputs()[y - 1]
    if output and y <= height then
        local ok, err = osApi.setOutput(output.name, not output.value)
        state.lastError = not ok and tostring(err) or nil
        return true
    end
    return false
end
return app
