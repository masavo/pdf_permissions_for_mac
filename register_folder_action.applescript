on run arguments
	if (count arguments) is not 2 then error "Expected folder path and installed script path"
	set target_path to item 1 of arguments
	set installed_script to item 2 of arguments
	-- Resolve paths before changing any Folder Actions settings.
	set target_alias to (POSIX file target_path) as alias
	set script_alias to (POSIX file installed_script) as alias
	set target_path to POSIX path of target_alias
	if target_path ends with "/" and target_path is not "/" then set target_path to text 1 thru -2 of target_path
	set installed_script to POSIX path of script_alias
	set script_hfs_path to script_alias as text
	tell application "System Events"
		set matching_actions to folder actions whose path is target_path
		if (count matching_actions) is 0 then
			set target_action to make new folder action with properties {path:target_path}
		else
			set target_action to item 1 of matching_actions
		end if
		tell target_action
			set matching_scripts to scripts whose POSIX path is installed_script
			if (count matching_scripts) is 0 then
				make new script with properties {path:script_hfs_path, enabled:true}
			else
				set enabled of item 1 of matching_scripts to true
			end if
			set enabled to true
		end tell
		set folder actions enabled to true
	end tell
	return "Registered: " & target_path
end run
