-- Built-in viewer commands. Inverse channels differ by viewer:
-- zathura fires both -x and D-Bus Edit for a click, so use D-Bus alone;
-- Okular runs an editor command, but only when the source file exists on disk;
-- Evince provides SyncView and SyncSource on D-Bus.
return {
  zathura = {
    name = 'zathura',
    open = { 'zathura', '@pdf' },
    forward = { 'zathura', '--synctex-forward', '@line:@column:@file', '@pdf' },
    listen = 'zathura',
  },
  okular = {
    name = 'okular',
    open = { 'okular', '--unique', '@pdf' },
    forward = { 'okular', '--unique', '@pdf#src:@line @file' },
    inverse = { '--editor-cmd', '@callback %f %l %c' },
    -- Owned by the running --unique instance; it rejects a second --editor-cmd.
    unique_bus = 'org.kde.okular',
  },
  evince = {
    name = 'evince',
    open = { 'evince', '@pdf' },
    forward = 'evince',
    listen = 'evince',
  },
}
