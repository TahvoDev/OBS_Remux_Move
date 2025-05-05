obs = obslua

-- Configuration
local source_directory = ""
local destination_directory = ""
local should_remux = true
local ffmpeg_path = ""
local log_file = nil
local sorting_mode = "yyyy-mm" -- default sorting mode: yyyy-mm, can be 'none' or 'yyyy-mm'

-- Initialize log file
local function init_logging()
    local appdata = os.getenv("APPDATA")
    local log_path = appdata .. "\\obs-studio\\logs\\remux_script.log"
    log_file = io.open(log_path, "a")
end

-- Log message with timestamp
local function log_message(message)
    if log_file then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        log_file:write(string.format("[%s] %s\n", timestamp, message))
        log_file:flush()
    end
    print(message)  -- Also print to OBS script log
end

-- Description displayed in the Scripts window
function script_description()
    return "Automatically remux and move recordings when recording stops"
end

-- Properties for the script
function script_properties()
    local props = obs.obs_properties_create()
    
    obs.obs_properties_add_path(props, "source_dir", "Source Directory", 
        obs.OBS_PATH_DIRECTORY, "", nil)
    
    obs.obs_properties_add_path(props, "destination_dir", "Destination Directory",
        obs.OBS_PATH_DIRECTORY, "", nil)
    
    obs.obs_properties_add_path(props, "ffmpeg_path", "FFmpeg Path (ffmpeg.exe)",
        obs.OBS_PATH_FILE,
        "FFmpeg Executable (*.exe);;All Files (*.*)", nil)
    
    obs.obs_properties_add_bool(props, "should_remux", "Remux files (if disabled, files will only be moved)")
    
    local sorting_list = obs.obs_properties_add_list(props, "sorting_mode", "Sorting Mode", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(sorting_list, "No Sorting (all files in root)", "none")
    obs.obs_property_list_add_string(sorting_list, "Sort by YYYY-MM", "yyyy-mm")
    -- Add more options here if desired
    return props
end

-- Called when script settings are updated
function script_update(settings)
    source_directory = obs.obs_data_get_string(settings, "source_dir")
    destination_directory = obs.obs_data_get_string(settings, "destination_dir")
    ffmpeg_path = obs.obs_data_get_string(settings, "ffmpeg_path")
    should_remux = obs.obs_data_get_bool(settings, "should_remux")
    sorting_mode = obs.obs_data_get_string(settings, "sorting_mode") or "yyyy-mm"
end

-- Find the most recent recording file
function find_latest_recording()
    if source_directory == "" then return nil end
    
    local latest_file = nil
    local latest_time = 0
    
    local handle = io.popen('dir "' .. source_directory .. '" /b /a-d')
    if handle then
        for file in handle:lines() do
            -- Check if file has video extension
            local ext = string.lower(string.match(file, "%.([^%.]+)$"))
            if ext == "mkv" or ext == "mp4" or ext == "mov" or ext == "flv" then
                local full_path = source_directory .. "\\" .. file
                local attr = os.execute('dir "' .. full_path .. '" /a:-d >nul 2>&1')
                if attr then
                    local mtime = 0
                    handle2 = io.popen('powershell -Command "(Get-Item \'' .. full_path:gsub("'", "''") .. '\').LastWriteTime.Ticks"')
                    if handle2 then
                        mtime = tonumber(handle2:read("*a")) or 0
                        handle2:close()
                    end
                    
                    if mtime > latest_time then
                        latest_time = mtime
                        latest_file = full_path
                    end
                end
            end
        end
        handle:close()
    end
    
    return latest_file
end

-- Handle the recording stopped event
function handle_recording_stopped()
    if source_directory == "" or destination_directory == "" then
        log_message("Source or destination directory not configured!")
        return
    end
    
    -- Use a single PowerShell command for all operations
    local timestamp = os.date("%Y%m%d_%H%M%S")
    local ps_script
    -- Determine target subfolder based on sorting_mode
    local subfolder = ""
    if sorting_mode == "yyyy-mm" then
        subfolder = os.date("%Y-%m")
    end
    local final_dest_dir = destination_directory
    if subfolder ~= "" then
        final_dest_dir = destination_directory .. "\\" .. subfolder
        -- Create the subfolder if it doesn't exist
        os.execute('if not exist "' .. final_dest_dir .. '" mkdir "' .. final_dest_dir .. '"')
    end

    if should_remux then
        if ffmpeg_path == "" then
            log_message("Error: FFmpeg path not configured!")
            return
        end
        ps_script = string.format([[
            $ErrorActionPreference = 'Stop'
            $srcDir = '%s'
            $dstDir = '%s'
            $ffmpeg = '%s'
            Write-Output 'Source Dir: ' $srcDir
            Write-Output 'Dest Dir: ' $dstDir
            Write-Output 'FFmpeg:' $ffmpeg
            $files = Get-ChildItem -Path "$srcDir" -File | Where-Object { $_.Extension -match '\.(mkv|mp4|mov|flv)$' }
            if ($files) {
                $latest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                Write-Output 'Latest file: ' $latest.FullName
                $base = [System.IO.Path]::GetFileNameWithoutExtension($latest.Name)
                $timestamp = '%s'
                $temp = Join-Path $srcDir ($base + '_remuxed_' + $timestamp + '.mp4')
                $target = Join-Path $dstDir ($base + '_remuxed_' + $timestamp + '.mp4')
                Write-Output 'Temp file: ' $temp
                Write-Output 'Target file: ' $target
                & "$ffmpeg" -hide_banner -i "$($latest.FullName)" -c copy "$temp"
                if (Test-Path $temp) {
                    Move-Item "$temp" "$target" -Force
                    Write-Output 'Successfully remuxed and moved file to: ' $target
                    Write-Output 'Original file kept at: ' + $($latest.FullName)
                } else {
                    Write-Output 'FFmpeg failed to create output file'
                }
            } else {
                Write-Output 'No recording file found!'
                Write-Output 'Directory listing for diagnostics:'
                Get-ChildItem -Path "$srcDir" -File | ForEach-Object { Write-Output $_.Name }
            }
        ]], source_directory, final_dest_dir, ffmpeg_path, timestamp)
    else
        ps_script = string.format([[
            $ErrorActionPreference = 'Stop'
            $srcDir = "%s"
            $dstDir = "%s"
            Write-Output 'Source Dir: ' $srcDir
            Write-Output 'Dest Dir: ' $dstDir
            $files = Get-ChildItem -Path "$srcDir" -File | Where-Object { $_.Extension -match '\.(mkv|mp4|mov|flv)$' }
            if ($files) {
                $latest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                Write-Output 'Latest file: ' $latest.FullName
                $base = [System.IO.Path]::GetFileNameWithoutExtension($latest.Name)
                $timestamp = '%s'
                $target = Join-Path $dstDir ($base + '_' + $timestamp + $latest.Extension)
                Write-Output 'Target file: ' $target
                Copy-Item "$($latest.FullName)" "$target" -Force
                Write-Output 'Successfully copied file to: ' $target
                Write-Output 'Original file kept at: ' + $($latest.FullName)
            } else {
                Write-Output 'No recording file found!'
                Write-Output 'Directory listing for diagnostics:'
                Get-ChildItem -Path "$srcDir" -File | ForEach-Object { Write-Output $_.Name }
            }
        ]], source_directory, final_dest_dir, timestamp)
    end
    log_message('Running PowerShell command: ' .. ps_script)
    local handle = io.popen('powershell -Command "' .. ps_script:gsub('"', '\"'):gsub("\n", ";") .. '"')
    local output = handle:read("*a")
    handle:close()
    if output and output:match('%S') then
        log_message("POWERSHELL OUTPUT:\n" .. output)
    else
        log_message('No output from PowerShell script')
    end
end

-- Called when OBS triggers an event
function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        handle_recording_stopped()
    end
end

function script_load(settings)
    init_logging()
    log_message("Remux script loaded")
    obs.obs_frontend_add_event_callback(on_event)
end

function script_unload()
    if log_file then
        log_message("Remux script unloaded")
        log_file:close()
        log_file = nil
    end
end
