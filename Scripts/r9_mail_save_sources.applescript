-- R9 (native mail half): write the raw source Apple Mail holds for every message of
-- On My Mac ▸ Import ▸ <argv[2]> to argv[1]/NN.eml (NN = position in the mailbox, by
-- date received), plus argv[1]/mail-readback.tsv (message id, subject, attachment names).
-- These .eml files are the "derived EML of the same messages": Mail's own source text.
-- Reads only the named child of the "Import" mailbox.
on run argv
	set dest to item 1 of argv
	set boxName to item 2 of argv
	do shell script "mkdir -p " & quoted form of dest
	set out to {}
	tell application "Mail"
		set box to mailbox boxName of mailbox "Import"
		set msgs to every message of box
		set i to 0
		repeat with m in msgs
			set i to i + 1
			set n to text -2 thru -1 of ("0" & i)
			set src to source of m
			set fh to open for access (POSIX file (dest & "/" & n & ".eml")) with write permission
			set eof of fh to 0
			write src to fh as «class utf8»
			close access fh
			set names to {}
			repeat with a in (every mail attachment of m)
				set end of names to (name of a)
			end repeat
			set AppleScript's text item delimiters to "|"
			set nameText to names as string
			set AppleScript's text item delimiters to ""
			set end of out to n & tab & (message id of m) & tab & (subject of m) & tab & nameText
		end repeat
	end tell
	set AppleScript's text item delimiters to linefeed
	set t to out as string
	set AppleScript's text item delimiters to ""
	set fh to open for access (POSIX file (dest & "/mail-readback.tsv")) with write permission
	set eof of fh to 0
	write t to fh as «class utf8»
	close access fh
	return (count of out) as string
end run
