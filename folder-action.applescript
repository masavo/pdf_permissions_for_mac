-- The installer replaces this placeholder with the current checkout path.
property secure_script : "__SECURE_PDF_SCRIPT__"

on adding folder items to this_folder after receiving added_items

	repeat with added_item in added_items
		set item_path to POSIX path of added_item
		set lower_path to do shell script "printf %s " & quoted form of item_path & " | tr '[:upper:]' '[:lower:]'"
		if lower_path ends with ".pdf" then
			try
				do shell script "/bin/bash " & quoted form of secure_script & " " & quoted form of item_path
			on error error_message number error_number
				-- qpdf errors may include sensitive arguments: record only the code/path.
				set error_log to (POSIX path of (path to library folder from user domain)) & "Logs/PDF自動権限付与-folder-action.log"
				do shell script "/bin/mkdir -p " & quoted form of ((POSIX path of (path to library folder from user domain)) & "Logs") & "; /usr/bin/printf '%s [ERROR] Folder Action failed (%s): %s\\n' \"$(/bin/date '+%Y-%m-%d %H:%M:%S')\" " & quoted form of (error_number as text) & " " & quoted form of item_path & " >> " & quoted form of error_log
			end try
		end if
	end repeat
end adding folder items to
