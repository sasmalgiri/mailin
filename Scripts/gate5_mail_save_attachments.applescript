-- OUT-05 / gate 5: save each attachment and each message source that Apple
-- Mail holds in Import ▸ <child> to argv[1]/<child>/, so their bytes can be
-- hashed against the inventory. Reads only the "Import" mailbox.
on run argv
	set dest to item 1 of argv
	tell application "Mail"
		repeat with child in (every mailbox of mailbox "Import")
			set childName to name of child
			do shell script "mkdir -p " & quoted form of (dest & "/" & childName)
			repeat with m in (every message of child)
				set mid to message id of m
				set src to source of m
				set srcPath to dest & "/" & childName & "/" & mid & ".source.eml"
				set fh to open for access (POSIX file srcPath) with write permission
				set eof of fh to 0
				write src to fh as «class utf8»
				close access fh
				repeat with a in (every mail attachment of m)
					save a in (POSIX file (dest & "/" & childName & "/" & mid & "__" & (name of a)))
				end repeat
			end repeat
		end repeat
	end tell
	return "ok"
end run
