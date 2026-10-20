-- FX Inspector
-- Version 1.0.1

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox(
        "ReaImGui is not available.\n" ..
        "Check the installation and restart REAPER.",
        "FX Inspector", 0
    )
    return
end

-- Prevent multiple instances of FX Inspector from running at the same time.
local INSTANCE_SECTION = "FX Inspector"
if reaper.GetExtState(INSTANCE_SECTION, "running") == "1" then
    return
end
reaper.SetExtState(INSTANCE_SECTION, "running", "1", false)
reaper.atexit(function()
    reaper.DeleteExtState(INSTANCE_SECTION, "running", false)
end)

local ctx = reaper.ImGui_CreateContext("FX Inspector")

-- true: user mode (hide the diagnostic column); false: debug mode (show it).
local USER_MODE = true

local SEARCH_STEP = 0.001
local MAX_SEARCH_STEPS = 1000
local FALLBACK_STEP = 0.001

-- Local step estimation settings.
local LOCAL_SEARCH_ITERATIONS = 12

-- Number of draw cycles between parameter-value refreshes.
-- Set to 1 to refresh values on every cycle; higher values reduce API calls.
local REFRESH_INTERVAL = 16

-- Hold-to-repeat timing, in seconds.
local HOLD_DELAY = 0.350
local REPEAT_INTERVAL = 0.050

local step_cache = {}
local cached_fx_key = nil
local repeat_state = {}

-- Cache parameter metadata for the currently selected FX.
local metadata_cache_key = nil
local metadata_cache = nil

-- Cache parameter values between refresh cycles.
local value_cache_key = nil
local value_cache = {}
local value_refresh_counter = 0
local force_value_refresh = true

-- Resolve the focused FX and select the appropriate REAPER API family.
-- Track FX use TrackFX_*; item FX and take FX use TakeFX_*.
local function get_focused_fx()
    local retval, trackidx, itemidx, takeidx, fxidx =
        reaper.GetTouchedOrFocusedFX(1)

    if not retval then
        return nil, "NO FOCUSED FX DETECTED!"
    end

    local fx = {
        trackidx = trackidx,
        itemidx = itemidx,
        takeidx = takeidx,
        fxidx = fxidx
    }

    if itemidx ~= -1 then
        -- Item FX and take FX are identified by itemidx; takeidx == -1
        -- denotes the item FX chain, while a non-negative takeidx denotes
        -- a specific take FX chain.
        local track = reaper.GetTrack(0, trackidx)
        if not track then
            return nil, "Could not identify the item's track."
        end

        local item = reaper.GetTrackMediaItem(track, itemidx)
        if not item then
            return nil, "Could not identify the focused media item."
        end

        fx.track = track
        fx.item = item
        fx.api_prefix = "TakeFX_"

        if takeidx == -1 then
            fx.kind = "item"
            -- REAPER exposes item FX through the TakeFX API using a nil take.
            fx.target = nil
            fx.key = table.concat({"item", tostring(item), tostring(fxidx)}, ":")
        else
            local take = reaper.GetTake(item, takeidx)
            if not take then
                return nil, "Could not identify the focused take."
            end
            fx.kind = "take"
            fx.take = take
            fx.target = take
            fx.key = table.concat({"take", tostring(item), tostring(take), tostring(fxidx)}, ":")
        end
    else
        local track
        if trackidx == -1 then
            track = reaper.GetMasterTrack(0)
        else
            track = reaper.GetTrack(0, trackidx)
        end

        if not track then
            return nil, "Could not identify the track."
        end

        fx.kind = "track"
        fx.track = track
        fx.target = track
        fx.api_prefix = "TrackFX_"
        fx.key = table.concat({"track", tostring(track), tostring(trackidx), tostring(fxidx)}, ":")
    end

    local name_fn = reaper[fx.api_prefix .. "GetFXName"]
    if not name_fn then
        return nil, "The required REAPER FX API is unavailable."
    end

    local call_ok, ok, fxname = pcall(name_fn, fx.target, fxidx, "")
    if not call_ok or not ok then
        return nil, "Could not retrieve the FX name."
    end

    -- Clean the FX name for display.
    fxname = fxname:gsub("^[^:]+:%s*", "")
    fxname = fxname:gsub("%s*%([^()]*%)$", "")

    local guid_fn = reaper[fx.api_prefix .. "GetFXGUID"]
    local guid
    if guid_fn then
        local guid_call_ok, guid_result = pcall(guid_fn, fx.target, fxidx)
        if guid_call_ok then
            guid = guid_result
        end
    end
    fx.name = fxname
    fx.guid = guid or fxname
    fx.key = fx.key .. ":" .. tostring(fx.guid)

    -- Build a human-readable source label and determine the FX chain position.
    local chain_index = fxidx
    local chain_count = 0

    -- Safely query named FX configuration values. Container-related keys are
    -- not available for every FX, so failed queries simply return nil.
    local function get_named_config(fx_track, index, key)
        local fn = reaper.TrackFX_GetNamedConfigParm
        if not fn then
            return nil
        end

        local call_ok, success, value =
            pcall(fn, fx_track, index, key)

        if call_ok and success and value ~= nil and value ~= "" then
            return value
        end

        return nil
    end

    -- Find an FX's 1-based position among the direct children of a container.
    local function get_container_child_position(fx_track, container_index, child_index)
        local count_text = get_named_config(
            fx_track, container_index, "container_count"
        )
        local count = tonumber(count_text)

        if not count or count < 0 then
            return nil, nil
        end

        for i = 0, count - 1 do
            local item_index = get_named_config(
                fx_track, container_index, "container_item." .. i
            )

            if item_index ~= nil
                and tonumber(item_index) == tonumber(child_index) then
                return i + 1, count
            end
        end

        return nil, count
    end

    -- Determine whether an FX is a container by checking its child-count key.
    local function is_container(fx_track, index)
        return get_named_config(fx_track, index, "container_count") ~= nil
    end

    -- Find a container's ordinal among container siblings only.
    -- Ordinary FX siblings do not affect the displayed container number.
    local function get_container_ordinal(fx_track, container_index)
        local parent_text = get_named_config(
            fx_track, container_index, "parent_container"
        )
        local parent_index = tonumber(parent_text)
        local ordinal = 0

        if parent_index ~= nil then
            local count = tonumber(get_named_config(
                fx_track, parent_index, "container_count"
            ))
            if not count or count < 0 then
                return nil
            end

            for i = 0, count - 1 do
                local item_index = tonumber(get_named_config(
                    fx_track, parent_index, "container_item." .. i
                ))
                if item_index ~= nil and is_container(fx_track, item_index) then
                    ordinal = ordinal + 1
                    if item_index == tonumber(container_index) then
                        return ordinal
                    end
                end
            end
        else
            -- This is a top-level container: inspect the main track FX chain.
            local count = reaper.TrackFX_GetCount(fx_track) or 0
            for i = 0, count - 1 do
                if is_container(fx_track, i) then
                    ordinal = ordinal + 1
                    if i == tonumber(container_index) then
                        return ordinal
                    end
                end
            end
        end

        return nil
    end

    -- Return the parent-container path (outermost first) and the focused FX's
    -- position within its immediate parent container.
    local function get_container_path(fx_track, focused_index)
        local parent_text = get_named_config(
            fx_track, focused_index, "parent_container"
        )
        local parent_index = tonumber(parent_text)

        if parent_index == nil then
            return nil, nil, nil
        end

        local child_position, child_count = get_container_child_position(
            fx_track, parent_index, focused_index
        )
        if not child_position then
            return nil, nil, nil
        end

        local inner_to_outer = {}
        local seen = {}
        local current_parent = parent_index

        -- A parent index of 0 is valid. Stop when that container has no parent.
        while current_parent ~= nil and not seen[current_parent]
            and #inner_to_outer < 32 do
            seen[current_parent] = true
            inner_to_outer[#inner_to_outer + 1] = current_parent
            current_parent = tonumber(get_named_config(
                fx_track, current_parent, "parent_container"
            ))
        end

        local path = {}
        for i = #inner_to_outer, 1, -1 do
            local ordinal = get_container_ordinal(fx_track, inner_to_outer[i])
            if not ordinal then
                return nil, nil, nil
            end
            path[#path + 1] = "Cont " .. ordinal
        end

        return path, child_position, child_count
    end

    if fx.kind == "track" then
        local _, track_name = reaper.GetTrackName(fx.track, "")
        track_name = (track_name and track_name ~= "") and track_name or "Track"

        if trackidx == -1 then
            fx.source_label = "Master"
        else
            fx.source_label = "Track: " .. track_name
        end

        -- Input FX and Monitoring FX use the 0x1000000 flag.
        if (fxidx & 0x1000000) ~= 0 then
            chain_index = fxidx & 0xFFFFFF
            chain_count = reaper.TrackFX_GetRecCount(fx.track) or 0

            if trackidx == -1 then
                fx.source_label = fx.source_label .. " · Monitoring FX "
            else
                fx.source_label = fx.source_label .. " · Input FX "
            end

            fx.source_label = fx.source_label .. (chain_index + 1) .. "/" .. chain_count
        else
            -- Container children have their own local chain positions. Do not
            -- use the encoded FX index as an index in the main track chain.
            local container_path, child_position, child_count =
                get_container_path(fx.track, fxidx)

            if container_path and child_position and child_count then
                fx.source_label = fx.source_label
                    .. " · " .. table.concat(container_path, " · ")
                    .. " · FX " .. child_position .. "/" .. child_count
            else
                chain_count = reaper.TrackFX_GetCount(fx.track) or 0
                fx.source_label = fx.source_label
                    .. " · FX " .. (chain_index + 1) .. "/" .. chain_count
            end
        end
    else
        local _, track_name = reaper.GetTrackName(fx.track, "")
        track_name = (track_name and track_name ~= "") and track_name or "Track"
        fx.source_label = "Track: " .. track_name .. " · Item " .. (itemidx + 1)

        if fx.kind == "take" then
            fx.source_label = fx.source_label .. " · Take " .. (takeidx + 1)
            chain_count = reaper.TakeFX_GetCount(fx.take) or 0
        else
            -- REAPER exposes item FX through TakeFX_* with a nil take pointer.
            local ok_count, count = pcall(reaper.TakeFX_GetCount, nil)
            chain_count = (ok_count and count) or 0
        end

        fx.source_label = fx.source_label .. " · FX "
            .. (chain_index + 1) .. "/" .. chain_count
    end

    return fx
end

-- Call the matching TrackFX_* or TakeFX_* API for this FX.
-- For item FX, target is nil and REAPER's TakeFX API addresses the item chain.
local function fx_call(fx, suffix, ...)
    local fn = reaper[fx.api_prefix .. suffix]
    if not fn then
        return nil
    end

    -- The item-FX API path uses a nil take pointer. Protect this path so
    -- an unsupported call reports no data instead of stopping the script.
    if fx.kind == "item" then
        local result = table.pack(pcall(fn, fx.target, fx.fxidx, ...))
        if not result[1] then
            return nil
        end
        return table.unpack(result, 2, result.n)
    end

    return fn(fx.target, fx.fxidx, ...)
end

-- Hide REAPER host parameters such as bypass, wet and delta.
local function is_special_host_parameter(fx, p)
    local ok, ident = fx_call(fx, "GetParamIdent", p)

    if not ok or type(ident) ~= "string" then
        return false
    end

    return ident:match("bypass$") ~= nil
        or ident:match("wet$") ~= nil
        or ident:match("delta$") ~= nil
end

local function get_visible_parameters(fx)
    local count = fx_call(fx, "GetNumParams") or 0

    local visible = {}

    for p = 0, count - 1 do
        if not is_special_host_parameter(fx, p) then
            visible[#visible + 1] = p
        end
    end

    return visible
end

-- Retrieve and cache parameter names, visible parameter indices,
-- and the width required by the parameter-name column.
local function get_parameter_metadata(fx)
    local key = fx.key

    -- Reuse cached metadata if the FX has not changed.
    if key == metadata_cache_key and metadata_cache then
        return metadata_cache
    end

    local visible_params = get_visible_parameters(fx)
    local parameter_names = {}
    local parameter_column_width = 0

    for _, p in ipairs(visible_params) do
        local _, name = fx_call(fx, "GetParamName", p, "")

        if not name or name == "" then
            name = "Parameter " .. (p + 1)
        end

        parameter_names[p] = name

        local width = reaper.ImGui_CalcTextSize(ctx, name)

        if width > parameter_column_width then
            parameter_column_width = width
        end
    end

    -- Add room for cell padding.
    parameter_column_width = parameter_column_width + 20

    metadata_cache = {
        visible_params = visible_params,
        parameter_names = parameter_names,
        parameter_column_width = parameter_column_width
    }

    metadata_cache_key = key

    return metadata_cache
end

-- Format a hypothetical value without changing the actual parameter.
local function get_formatted_at_value(fx, p, value)
    local ok, formatted =
        fx_call(fx, "FormatParamValue", p, value)

    if ok and type(formatted) == "string" then
        return formatted
    end

    return nil
end

local function get_step_info(fx, p)
    local ok, step, smallstep, largestep, istoggle =
        fx_call(fx, "GetParameterStepSizes", p)

    if not ok then
        return nil, nil, nil, false
    end

    if type(step) ~= "number" or step <= 0 then
        step = nil
    end

    return step, smallstep, largestep, istoggle
end

-- Estimate the first visible change from normalized value 0.
-- Used for initial diagnostics and as a fallback.
-- The actual plugin parameter is never changed during this search.
local function estimate_step(fx, p)
    local initial = get_formatted_at_value(fx, p, 0)

    if initial == nil then
        return nil
    end

    for i = 1, MAX_SEARCH_STEPS do
        local test_value = i * SEARCH_STEP
        local formatted =
            get_formatted_at_value(fx, p, test_value)

        if formatted == nil then
            return nil
        end

        if formatted ~= initial then
            return test_value
        end
    end

    return nil
end

-- Estimate the smallest normalized change that produces a different
-- formatted value from the current position, in the requested direction.
-- Exponential search brackets the change; binary search refines it.
-- No actual parameter value is changed during this calculation.
local function estimate_local_step(
    fx, p, value, direction, minval, maxval
)
    local initial = get_formatted_at_value(fx, p, value)

    if initial == nil then
        return nil
    end

    local available

    if direction > 0 then
        available = maxval - value
    else
        available = value - minval
    end

    if available <= 0 then
        return nil
    end

    local low = 0
    local high = math.min(SEARCH_STEP, available)

    local function format_at_delta(delta)
        local candidate = value + direction * delta

        candidate = math.max(
            minval, math.min(maxval, candidate)
        )

        return get_formatted_at_value(fx, p, candidate)
    end

    local formatted = format_at_delta(high)

    if formatted == nil then
        return nil
    end

    -- Find an interval containing the first visible change.
    while formatted == initial and high < available do
        low = high
        high = math.min(high * 2, available)

        formatted = format_at_delta(high)

        if formatted == nil then
            return nil
        end
    end

    -- No different formatted value was found in this direction.
    if formatted == initial then
        return nil
    end

    -- Refine the threshold without changing the real parameter.
    for _ = 1, LOCAL_SEARCH_ITERATIONS do
        local mid = (low + high) / 2

        if mid <= low or mid >= high then
            break
        end

        local mid_formatted = format_at_delta(mid)

        if mid_formatted == nil then
            return nil
        end

        if mid_formatted == initial then
            low = mid
        else
            high = mid
        end
    end

    -- 'high' is the smallest tested delta that changes the display.
    return high
end

local function initialize_step_cache(fx, visible_params)
    local key = fx.key

    if key == cached_fx_key then
        return
    end

    cached_fx_key = key
    step_cache = {}
    repeat_state = {}

    for _, p in ipairs(visible_params) do
        local api_step = get_step_info(fx, p)

        if api_step then
            step_cache[p] = {
                step = api_step,
                source = "API"
            }
        else
            local estimated = estimate_step(fx, p)

            if estimated and estimated > 0 then
                step_cache[p] = {
                    step = estimated,
                    source = "Estimated"
                }
            else
                step_cache[p] = {
                    step = FALLBACK_STEP,
                    source = "Default"
                }
            end
        end
    end
end

local function set_param_value(fx, p, value, minval, maxval)
    value = math.max(minval, math.min(maxval, value))

    fx_call(fx, "SetParam", p, value)
end

-- Apply one adjustment in the requested direction.
local function adjust_parameter(
    fx, p, direction, binary,
    adjustment_step, minval, maxval, cached, speed_multiplier
)
    local value = fx_call(fx, "GetParam", p)

    if type(value) ~= "number" then
        return
    end

    if binary then
        value = direction < 0 and 0 or 1
    else
        -- API steps remain unchanged.
        -- For estimated/default steps, calculate a local step at
        -- the current position in the requested direction.
        if cached and cached.source ~= "API" then
            local local_step = estimate_local_step(
                fx, p, value, direction, minval, maxval
            )

            if local_step and local_step > 0 then
                adjustment_step = local_step
                cached.step = local_step
            end
        end

        value = value + direction * adjustment_step * speed_multiplier
    end

    set_param_value(fx, p, value, minval, maxval)
end

-- Handle a button press and subsequent hold-to-repeat.
-- Return true when an adjustment was applied.
local function handle_adjust_button(
    fx, p, direction, binary, adjustment_step,
    minval, maxval, cached, activated, active, speed_multiplier
)
    local key = tostring(p) .. ":" .. tostring(direction)
    local now = reaper.time_precise()
    local did_adjust = false

    if activated then
        -- Always apply one adjustment immediately.
        adjust_parameter(
            fx, p, direction, binary,
            adjustment_step, minval, maxval, cached, speed_multiplier
        )
        did_adjust = true

        if not binary then
            repeat_state[key] = {
                next_time = now + HOLD_DELAY
            }
        else
            repeat_state[key] = nil
        end

    elseif active and not binary then
        local state = repeat_state[key]

        if state and now >= state.next_time then
            adjust_parameter(
                fx, p, direction, false,
                adjustment_step, minval, maxval, cached, speed_multiplier
            )

            state.next_time = now + REPEAT_INTERVAL
            did_adjust = true
        end

    else
        -- The button has been released.
        repeat_state[key] = nil
    end

    return did_adjust
end

local function draw_parameters(fx)
    -- Retrieve cached metadata instead of recalculating it every frame.
    local metadata = get_parameter_metadata(fx)

    local visible_params = metadata.visible_params
    local parameter_names = metadata.parameter_names
    local parameter_column_width = metadata.parameter_column_width

    initialize_step_cache(fx, visible_params)

    -- Reset the value cache immediately when the focused FX changes.
    local fx_key = fx.key

    if fx_key ~= value_cache_key then
        value_cache_key = fx_key
        value_cache = {}
        value_refresh_counter = 0
        force_value_refresh = true
    end

    value_refresh_counter = value_refresh_counter + 1

    -- Refresh all parameter values periodically, or immediately after
    -- a button adjustment or an FX change.
    local refresh_values = force_value_refresh
        or value_refresh_counter >= math.max(1, REFRESH_INTERVAL)

    if refresh_values then
        for _, p in ipairs(visible_params) do
            local formatted_ok, formatted =
                fx_call(fx, "GetFormattedParamValue", p)

            if not formatted_ok
                or not formatted
                or formatted == "" then
                formatted = "—"
            end

            local value, minval, maxval =
                fx_call(fx, "GetParam", p)

            value_cache[p] = {
                formatted = formatted,
                value = value,
                minval = minval,
                maxval = maxval
            }
        end

        value_refresh_counter = 0
        force_value_refresh = false
    end

    -- Identify the FX source and show the parameter count on a separate line.
    reaper.ImGui_Text(ctx, fx.source_label or "FX source unavailable")
    reaper.ImGui_Text(ctx, tostring(#visible_params) .. " parameters")
    reaper.ImGui_Separator(ctx)

    local flags =
        reaper.ImGui_TableFlags_Borders() |
        reaper.ImGui_TableFlags_RowBg() |
        reaper.ImGui_TableFlags_Resizable() |
        reaper.ImGui_TableFlags_SizingFixedFit()

    local column_count = USER_MODE and 3 or 4
    local table_open = reaper.ImGui_BeginTable(
        ctx, "FXParameters", column_count, flags
    )

    if table_open then
        local ok, err = xpcall(function()
            reaper.ImGui_TableSetupColumn(
                ctx,
                "Parameter",
                reaper.ImGui_TableColumnFlags_WidthFixed(),
                parameter_column_width
            )

            reaper.ImGui_TableSetupColumn(ctx, "Plugin value")
            reaper.ImGui_TableSetupColumn(ctx, "Adjustment")
            if not USER_MODE then
                reaper.ImGui_TableSetupColumn(ctx, "Normalized value")
            end

            reaper.ImGui_TableHeadersRow(ctx)

            local key_mods = reaper.ImGui_GetKeyMods(ctx)
            local alt_down =
                (key_mods & reaper.ImGui_Mod_Alt()) ~= 0
            local ctrl_down =
                (key_mods & reaper.ImGui_Mod_Ctrl()) ~= 0

            -- Alt takes priority if both modifiers are held.
            local speed_multiplier = alt_down and 50
                or (ctrl_down and 10 or 1)

            for _, p in ipairs(visible_params) do
                local param_name = parameter_names[p]

                local current_values = value_cache[p]
                    or {
                        formatted = "—",
                        value = 0,
                        minval = 0,
                        maxval = 1
                    }

                local formatted = current_values.formatted
                local value = current_values.value
                local minval = current_values.minval
                local maxval = current_values.maxval

                local cached = step_cache[p] or {}
                local adjustment_step =
                    cached.step or FALLBACK_STEP

                local api_step =
                    cached.source == "API" and cached.step or nil

                local binary =
                    (formatted == "On" or formatted == "Off")
                    and not api_step

                reaper.ImGui_TableNextRow(ctx)

                -- Parameter name.
                reaper.ImGui_TableSetColumnIndex(ctx, 0)
                reaper.ImGui_Text(ctx, param_name)

                -- Formatted plugin value.
                reaper.ImGui_TableSetColumnIndex(ctx, 1)
                reaper.ImGui_Text(ctx, formatted)

                -- Decrement button.
                reaper.ImGui_TableSetColumnIndex(ctx, 2)

                local button_width = 34

                reaper.ImGui_Button(
                    ctx, "-##minus" .. p, button_width, 0
                )

                local minus_activated =
                    reaper.ImGui_IsItemActivated(ctx)
                local minus_active =
                    reaper.ImGui_IsItemActive(ctx)

                local minus_adjusted = handle_adjust_button(
                    fx, p, -1, binary, adjustment_step,
                    minval, maxval, cached,
                    minus_activated, minus_active, speed_multiplier
                )

                if minus_adjusted then
                    force_value_refresh = true
                end

                reaper.ImGui_SameLine(ctx, 0, 4)

                -- Increment button.
                reaper.ImGui_Button(
                    ctx, "+##plus" .. p, button_width, 0
                )

                local plus_activated =
                    reaper.ImGui_IsItemActivated(ctx)
                local plus_active =
                    reaper.ImGui_IsItemActive(ctx)

                local plus_adjusted = handle_adjust_button(
                    fx, p, 1, binary, adjustment_step,
                    minval, maxval, cached,
                    plus_activated, plus_active, speed_multiplier
                )

                if plus_adjusted then
                    force_value_refresh = true
                end

                -- Actual normalized value and step diagnostics (debug mode only).
                if not USER_MODE then
                    reaper.ImGui_TableSetColumnIndex(ctx, 3)

                    reaper.ImGui_Text(
                        ctx,
                        string.format(
                            "%.3f  |  Step: %s (%.6f)",
                            value,
                            cached.source or "Default",
                            adjustment_step
                        )
                    )
                end
            end
        end, debug.traceback)

        reaper.ImGui_EndTable(ctx)

        if not ok then
            error(err)
        end
    end
end

local function loop()
    -- Update the visible title while keeping a stable window ID.
    local fx, message = get_focused_fx()
    local window_title = "FX Inspector"

    if fx then
        window_title = window_title .. " - " .. fx.name
    end

    window_title = window_title .. "###FXInspector"

    reaper.ImGui_SetNextWindowBgAlpha(ctx, 1.0)

    local visible, open =
        reaper.ImGui_Begin(ctx, window_title, true)

    if visible then
        local ok, err = xpcall(function()
            if fx then
                draw_parameters(fx)
            else
                repeat_state = {}
                force_value_refresh = true
                value_cache_key = nil

                reaper.ImGui_Text(ctx, message)
                reaper.ImGui_Separator(ctx)
                reaper.ImGui_Text(
                    ctx,
                    "Select a track, item or take FX by opening its floating window\nor selecting it in the corresponding FX chain."
                )
            end
        end, debug.traceback)

        if not ok then
            reaper.ShowConsoleMsg(
                "FX Inspector error:\n" .. tostring(err) .. "\n"
            )
        end
    end

    reaper.ImGui_End(ctx)

    -- Close FX Inspector when Escape is pressed.
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
        open = false
    end

    if open then
        reaper.defer(loop)
    end
end

reaper.ImGui_SetNextWindowSize(
    ctx, 1100, 600, reaper.ImGui_Cond_FirstUseEver()
)

loop()
