-- OUT-05 / gate 5: read the mailboxes Apple Mail made from mailin's export
-- (On My Mac ▸ Import ▸ <child>) and print one tab-separated line per message:
-- mailbox, message id, subject, attachment names (joined by "|"),
-- attachment sizes (joined by "|"). Reads only the "Import" mailbox.
on run
	set out to {}
	tell application "Mail"
		set importBox to mailbox "Import"
		repeat with child in (every mailbox of importBox)
			set childName to name of child
			set end of out to "#MAILBOX" & tab & childName & tab & (count of messages of child)
			repeat with m in (every message of child)
				set names to {}
				set sizes to {}
				repeat with a in (every mail attachment of m)
					set end of names to (name of a)
					try
						set end of sizes to ((file size of a) as string)
					on error
						set end of sizes to "?"
					end try
				end repeat
				set AppleScript's text item delimiters to "|"
				set nameText to names as string
				set sizeText to sizes as string
				set AppleScript's text item delimiters to ""
				set end of out to childName & tab & (message id of m) & tab & (subject of m) & tab & nameText & tab & sizeText
			end repeat
		end repeat
	end tell
	set AppleScript's text item delimiters to linefeed
	set t to out as string
	set AppleScript's text item delimiters to ""
	return t
end run
