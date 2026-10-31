export const SITE = {
	name: 'Perch',
	title: 'Perch: a Dynamic Island for your Mac',
	description:
		'Perch turns the MacBook notch into a command center and floats the same island on external monitors: search, clipboard history, drop-to-convert and live status for Claude Code and Codex.',
	/** Self-signed universal DMG. The release workflow uploads an unversioned copy for this link. */
	downloadUrl: 'https://github.com/iyansr/Perch/releases/latest/download/Perch.dmg',
	/** Homebrew clears the quarantine flag that the self-signed DMG otherwise needs cleared by hand. */
	installCommands: ['brew trust --tap iyansr/perch', 'brew install --cask iyansr/perch/perch'],
	minimumOS: 'macOS 26 Tahoe or later',
};
