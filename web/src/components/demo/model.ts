export type Surface = 'idle' | 'glance' | 'home' | 'panel' | 'drop' | 'convert';
export type Display = 'notch' | 'island';
/** Pages the Home dock switches between; Activity is reached from Home. */
export type HomePage = 'home' | 'clipboard' | 'timer' | 'convert' | 'activity';
export type Tone = 'running' | 'attention' | 'done' | 'failed';

export type ActivityItem = {
	id: 'agent' | 'timer' | 'convert';
	title: string;
	detail: string;
	tone: Tone;
	/** Short text for the pill's right ear (countdown, percent). */
	trailing?: string;
	/** 0…1 drawn as a ring. */
	progress?: number;
};

export type TimerState =
	| { phase: 'off' }
	| { phase: 'running'; label: string; total: number; endsAt: number }
	| { phase: 'paused'; label: string; total: number; remaining: number }
	| { phase: 'done'; label: string; at: number };

export type ConvertState =
	| { phase: 'off' }
	| { phase: 'running'; output: string; startedAt: number }
	| { phase: 'done'; output: string; at: number };

export const TONE_RANK: Record<Tone, number> = { attention: 0, failed: 1, running: 2, done: 3 };

export function clock(ms: number) {
	const total = Math.max(0, Math.ceil(ms / 1000));
	return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}
