export type ResultKind = 'app' | 'setting' | 'command' | 'clip' | 'answer' | 'timer' | 'web';

export type Result = {
	id: string;
	kind: ResultKind;
	title: string;
	/** Right-aligned kind label, as in the app's result rows. */
	meta: string;
	/** Extra words that match but aren't shown (System Settings contents, command aliases). */
	keywords?: string;
	/** Tile colour standing in for the app icon. */
	tint?: string;
	/** Clipboard History command: opens the clipboard scope instead of running. */
	opensClipboard?: boolean;
	/** Timer result: minutes to start. */
	minutes?: number;
};

export const APPS: Result[] = [
	{ id: 'figma', kind: 'app', title: 'Figma', meta: 'Application', tint: '#1e1e1e' },
	{ id: 'ghostty', kind: 'app', title: 'Ghostty', meta: 'Application', tint: '#2b2d3a' },
	{ id: 'xcode', kind: 'app', title: 'Xcode', meta: 'Application', tint: '#1c7cf2' },
	{ id: 'safari', kind: 'app', title: 'Safari', meta: 'Application', tint: '#0a84ff' },
	{ id: 'notes', kind: 'app', title: 'Notes', meta: 'Application', tint: '#e8b923' },
	{ id: 'mail', kind: 'app', title: 'Mail', meta: 'Application', tint: '#2f8cf5' },
	{ id: 'calendar', kind: 'app', title: 'Calendar', meta: 'Application', tint: '#f2f2f2' },
	{ id: 'messages', kind: 'app', title: 'Messages', meta: 'Application', tint: '#30c552' },
	{ id: 'wallpaper', kind: 'setting', title: 'Wallpaper', meta: 'System Settings' },
	{ id: 'dock', kind: 'setting', title: 'Desktop & Dock', meta: 'System Settings', keywords: 'dock' },
	{ id: 'appearance', kind: 'setting', title: 'Appearance', meta: 'System Settings', keywords: 'dark mode light' },
	{ id: 'displays', kind: 'setting', title: 'Displays', meta: 'System Settings', keywords: 'resolution night shift' },
];

export type Clip = {
	id: string;
	type: 'Text' | 'Link' | 'Color' | 'Image';
	/** Row title; images show their size like the app ("Image 1360×783"). */
	title: string;
	/** Full text, or a CSS background for images and colours. */
	body: string;
	source: string;
	copied: string;
};

export const CLIPS: Clip[] = [
	{
		id: 'c1',
		type: 'Text',
		title: 'Jl. Sudirman No. 21, Jakarta',
		body: 'Jl. Sudirman No. 21, Jakarta',
		source: 'Notes',
		copied: 'Today at 09.41',
	},
	{
		id: 'c2',
		type: 'Image',
		title: 'Image 1360×783',
		body: 'linear-gradient(160deg,#ffcf70,#ff7a1a 55%,#3b2a1f)',
		source: 'Figma',
		copied: 'Today at 09.12',
	},
	{
		id: 'c3',
		type: 'Text',
		title: 'npm run build -- --watch',
		body: 'npm run build -- --watch',
		source: 'Ghostty',
		copied: 'Today at 08.55',
	},
	{ id: 'c4', type: 'Link', title: 'https://tinycast.dev/', body: 'https://tinycast.dev/', source: 'Safari', copied: 'Today at 08.30' },
	{ id: 'c5', type: 'Color', title: '#FF9F0A', body: '#FF9F0A', source: 'Figma', copied: 'Yesterday at 17.02' },
	{
		id: 'c6',
		type: 'Text',
		title: 'Standup moved to 10:30 tomorrow, same link as last week',
		body: 'Standup moved to 10:30 tomorrow, same link as last week',
		source: 'Messages',
		copied: 'Yesterday at 16.48',
	},
	{
		id: 'c7',
		type: 'Image',
		title: 'Image 548×436',
		body: 'linear-gradient(200deg,#1b1b1e,#3a3a40 60%,#ff9f0a)',
		source: 'Safari',
		copied: 'Yesterday at 15.20',
	},
];

export const COMMANDS: Result[] = [
	{
		id: 'cmd-clip',
		kind: 'command',
		title: 'Clipboard History',
		meta: 'Command',
		keywords: 'clip paste copy history',
		opensClipboard: true,
	},
	{ id: 'cmd-settings', kind: 'command', title: 'Settings', meta: 'Command', keywords: 'preferences hotkey shortcut' },
];

/** Root search, or the clipboard history scope the Clipboard module and command open. */
export type Scope = 'root' | 'clipboard';

/** Claude Code session the demo terminal plays back. `ask` pauses until the user answers. */
export type AgentStep =
	| { kind: 'tool'; text: string }
	| { kind: 'ask'; text: string }
	| { kind: 'out'; text: string }
	| { kind: 'done'; text: string };

export const AGENT_PROMPT = 'add rate limiting to the users route';

export const AGENT_SCRIPT: AgentStep[] = [
	{ kind: 'tool', text: 'Read src/routes/users.ts' },
	{ kind: 'tool', text: 'Write src/middleware/rate-limit.ts' },
	{ kind: 'tool', text: 'Edit src/routes/users.ts  +18 -2' },
	{ kind: 'ask', text: 'Bash(npm test)' },
	{ kind: 'tool', text: 'Bash npm test' },
	{ kind: 'out', text: '24 passed, 0 failed' },
	{ kind: 'done', text: 'Rate limiting is on /users: 100 requests a minute per key.' },
];

export type ConvertAction = { id: string; label: string; ext: string; suffix: string };

/** Same actions and naming as Perch/Convert/ConversionAction.swift for an image drop. */
export const CONVERT_ACTIONS: ConvertAction[] = [
	{ id: 'png', label: 'PNG', ext: 'png', suffix: '' },
	{ id: 'jpg', label: 'JPG', ext: 'jpg', suffix: '' },
	{ id: 'webp', label: 'WebP', ext: 'webp', suffix: '' },
	{ id: 'resize', label: 'Resize 50%', ext: 'heic', suffix: '-50' },
	{ id: 'compress', label: 'Compress', ext: 'heic', suffix: '-compressed' },
];

export const SOURCE_FILE = { base: 'Screenshot', ext: 'heic', size: '4.1 MB' };

/** Other agent sessions Home's Agents tile lists beside the live Claude one. */
export const OTHER_AGENTS = [
	{ id: 'codex', source: 'codex', title: 'Codex · web', status: 'running', age: '8m' },
	{ id: 'watch', source: 'watch', title: 'pnpm build', status: 'done', age: '24m' },
] as const;

export const TRACK = { title: 'Danger Line', artist: 'Avenged Sevenfold', duration: 329 };
export const MEETING = { title: 'Sprint standup', time: '10:00', app: 'Zoom' };
export const WEATHER = { temp: '24°', place: 'Jakarta' };
export const DEVICES = [
	{ name: 'AirPods Pro', percent: 64 },
	{ name: 'Magic Mouse', percent: 18 },
];
