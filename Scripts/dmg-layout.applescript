-- Lays out the release DMG's Finder window: large icons, the background
-- arrow, Plainsay.app on the left and Applications on the right.
--
--   osascript Scripts/dmg-layout.applescript "/Volumes/Plainsay 0.2.38" "Plainsay 0.2.38"
--
-- Called by release.sh straight after `hdiutil attach`. Finder learns about a
-- freshly attached volume asynchronously, so a bare `tell disk "<name>"` at
-- that moment can fail with -1728 ("Can't get disk") — which is what aborted
-- 0.2.38 twice. So: wait (up to ~20 s) for Finder to see the disk, address it
-- through the mount point hdiutil reported rather than an assumed name, and
-- retry the layout itself a few times before giving up. Exits non-zero if it
-- never succeeds; release.sh then ships a plain DMG instead of aborting.
on run argv
	set mountPath to item 1 of argv
	set volumeName to item 2 of argv

	set dmgDisk to missing value
	repeat 20 times
		try
			set mountAlias to (POSIX file mountPath) as alias
			tell application "Finder" to set dmgDisk to disk of mountAlias
		end try
		-- By name only as a fallback, and only with the name taken from the
		-- mount point: a stale volume of the same name mounts this one as
		-- "<name> 1", and then the plain name would point at the wrong disk.
		if dmgDisk is missing value then
			try
				tell application "Finder"
					if exists disk volumeName then set dmgDisk to disk volumeName
				end tell
			end try
		end if
		if dmgDisk is not missing value then exit repeat
		delay 1
	end repeat
	if dmgDisk is missing value then error "Finder never saw the volume at " & mountPath number -1728

	set lastError to ""
	repeat with attempt from 1 to 3
		try
			with timeout of 60 seconds
				tell application "Finder"
					tell dmgDisk
						open
						set current view of container window to icon view
						set toolbar visible of container window to false
						set statusbar visible of container window to false
						set the bounds of container window to {400, 100, 1060, 500}
						set theViewOptions to icon view options of container window
						set arrangement of theViewOptions to not arranged
						set icon size of theViewOptions to 128
						set background picture of theViewOptions to file ".background:background.png"
						set position of item "Plainsay.app" of container window to {180, 195}
						set position of item "Applications" of container window to {480, 195}
						select {}
						close
						open
						update without registering applications
						delay 1
					end tell
				end tell
			end timeout
			return
		on error errMsg number errNum
			set lastError to errMsg & " (" & errNum & ")"
			log "Finder layout attempt " & attempt & "/3 failed: " & lastError
			delay 2
		end try
	end repeat
	error "Finder layout failed after 3 attempts: " & lastError
end run
