return {
  'tpope/vim-sleuth',
  -- Disabled: sleuth auto-detects per-file indent and sets noexpandtab when a
  -- file (or its siblings) uses tabs, overriding the global "4 spaces, never
  -- tabs" setup. We always want 4 spaces, so the autodetect is unwanted.
  enabled = false,
}
