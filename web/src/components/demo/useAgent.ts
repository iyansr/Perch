import { useEffect, useReducer } from 'react';
import { AGENT_SCRIPT } from './data';

export type AgentStatus = 'running' | 'input' | 'done' | 'failed';

export type AgentLine = { id: number; kind: 'tool' | 'ask' | 'out' | 'done' | 'note'; text: string };

type State = { step: number; status: AgentStatus; lines: AgentLine[]; dismissed: boolean };

type Action = { type: 'advance' } | { type: 'allow' } | { type: 'deny' } | { type: 'dismiss' } | { type: 'restart' };

const STEP_MS = 1400;
/** Done and failed activities leave the notch after 8 s (PRD F3). */
const DISMISS_MS = 8000;

const initial: State = { step: 0, status: 'running', lines: [], dismissed: false };

function reducer(state: State, action: Action): State {
	switch (action.type) {
		case 'advance': {
			const step = AGENT_SCRIPT[state.step];
			if (!step || state.status !== 'running') return state;
			const line: AgentLine = { id: state.step, kind: step.kind, text: step.text };
			if (step.kind === 'ask') return { ...state, status: 'input', lines: [...state.lines, line] };
			if (step.kind === 'done') return { ...state, status: 'done', step: state.step + 1, lines: [...state.lines, line] };
			return { ...state, step: state.step + 1, lines: [...state.lines, line] };
		}
		case 'allow':
			if (state.status !== 'input') return state;
			return {
				...state,
				status: 'running',
				step: state.step + 1,
				lines: [...state.lines, { id: 100 + state.step, kind: 'note', text: 'Allowed' }],
			};
		case 'deny':
			if (state.status !== 'input') return state;
			return {
				...state,
				status: 'failed',
				lines: [...state.lines, { id: 100 + state.step, kind: 'note', text: 'Denied. Claude stopped the task.' }],
			};
		case 'dismiss':
			return { ...state, dismissed: true };
		case 'restart':
			return initial;
	}
}

/** Plays back a Claude Code session; it only advances while the demo is on screen. */
export function useAgent(playing: boolean) {
	const [state, dispatch] = useReducer(reducer, initial);

	useEffect(() => {
		if (!playing || state.status !== 'running') return;
		const id = window.setTimeout(() => dispatch({ type: 'advance' }), STEP_MS);
		return () => window.clearTimeout(id);
	}, [playing, state.status, state.step]);

	useEffect(() => {
		if (state.dismissed || (state.status !== 'done' && state.status !== 'failed')) return;
		const id = window.setTimeout(() => dispatch({ type: 'dismiss' }), DISMISS_MS);
		return () => window.clearTimeout(id);
	}, [state.status, state.dismissed]);

	return { ...state, dispatch };
}
