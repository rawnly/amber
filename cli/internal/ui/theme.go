package ui

import "charm.land/lipgloss/v2"

// Palette: an amber accent on neutral greys, with the usual status colours.
var (
	colorAccent = lipgloss.Color("#FFB000")
	colorInk    = lipgloss.Color("#1C1B1A")
	colorMuted  = lipgloss.Color("#7A7672")
	colorFaint  = lipgloss.Color("#4A4744")
	colorButton = lipgloss.Color("#2E2C2A")
	colorText   = lipgloss.Color("#E6E1DC")
	colorGreen  = lipgloss.Color("#8BC37A")
	colorRed    = lipgloss.Color("#E8686A")
	colorBlue   = lipgloss.Color("#7AA8E8")
	colorPurple = lipgloss.Color("#C49AE8")
	colorCyan   = lipgloss.Color("#6CC4C4")
	colorYellow = lipgloss.Color("#E8C468")
)

var (
	styleTitle        = lipgloss.NewStyle().Bold(true).Foreground(colorInk).Background(colorAccent).Padding(0, 1)
	styleButton       = lipgloss.NewStyle().Foreground(colorText).Background(colorButton).Padding(0, 1)
	styleButtonActive = lipgloss.NewStyle().Bold(true).Foreground(colorInk).Background(colorAccent).Padding(0, 1)
	styleKey          = lipgloss.NewStyle().Foreground(colorAccent)
	styleSection      = lipgloss.NewStyle().Bold(true).Foreground(colorText)
	styleCount        = lipgloss.NewStyle().Foreground(colorMuted)
	styleName         = lipgloss.NewStyle().Foreground(colorText)
	styleCursor       = lipgloss.NewStyle().Bold(true).Foreground(colorAccent)
	styleDim          = lipgloss.NewStyle().Foreground(colorMuted)
	styleFaint        = lipgloss.NewStyle().Foreground(colorFaint)
	styleHash         = lipgloss.NewStyle().Foreground(colorPurple)
	styleRef          = lipgloss.NewStyle().Foreground(colorBlue)
	styleOK           = lipgloss.NewStyle().Foreground(colorGreen)
	styleErr          = lipgloss.NewStyle().Foreground(colorRed)
	styleWarn         = lipgloss.NewStyle().Foreground(colorYellow)
	styleLocal        = lipgloss.NewStyle().Foreground(colorCyan)
	styleAccent       = lipgloss.NewStyle().Foreground(colorAccent)
	styleBarOn        = lipgloss.NewStyle().Foreground(colorAccent)
	styleBarOff       = lipgloss.NewStyle().Foreground(colorFaint)
)

// Icons, chosen to read without a Nerd Font.
const (
	iconInstalled = "●"
	iconMissing   = "○"
	iconFailed    = "✗"
	iconOutdated  = "↑"
	iconUpdated   = "✓"
	iconLocal     = "◆"
	iconDisabled  = "◌"
	iconBuild     = "⚙"
	iconCursor    = "›"
)
