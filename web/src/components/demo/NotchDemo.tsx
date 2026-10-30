import { AnimatePresence, motion, useInView, useMotionValue, useReducedMotion, useSpring, useTransform } from 'motion/react';
import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { buildSections, ClipboardPanel, filterClips, ResultsPanel, SearchRow } from './CommandPanel';
import { SOURCE_FILE, type Clip, type ConvertAction, type Result, type Scope } from './data';
import { DraggableFile, FileThumb, MenuBar, Terminal } from './Desktop';
import { HotkeyKeys } from './HotkeyKeys';
import { ActivityPage, CompactView, ConvertView, DropView, GlanceView, HomeView } from './IslandViews';
import { clock, TONE_RANK, type ActivityItem, type ConvertState, type Display, type Surface, type TimerState } from './model';
import { useAgent } from './useAgent';

/** Opening carries a hint of overshoot like the app's expand curve; closing settles without it. */
const SPRING_OPEN = { type: 'spring', bounce: 0.18, duration: 0.5 } as const;
const SPRING_CLOSE = { type: 'spring', bounce: 0, duration: 0.4 } as const;
const CONVERT_MS = 1400;
const DISMISS_MS = 8000;

function useNow(interval: number | null) {
	const [now, setNow] = useState(() => Date.now());
	useEffect(() => {
		if (interval === null) return;
		setNow(Date.now());
		const id = window.setInterval(() => setNow(Date.now()), interval);
		return () => window.clearInterval(id);
	}, [interval]);
	return now;
}

export default function NotchDemo() {
	const stageRef = useRef<HTMLDivElement>(null);
	const islandRef = useRef<HTMLDivElement>(null);
	const inputRef = useRef<HTMLInputElement>(null);
	const triggerRef = useRef<HTMLButtonElement>(null);
	const hoverTimer = useRef<number | undefined>(undefined);
	const dropHotRef = useRef(false);
	const reduce = useReducedMotion();
	const inView = useInView(stageRef, { amount: 0.35 });

	const [display, setDisplay] = useState<Display>('notch');
	const [surface, setSurface] = useState<Surface>('idle');
	const [stageW, setStageW] = useState(1000);
	const [contentH, setContentH] = useState(0);
	const [query, setQuery] = useState('');
	const [scope, setScope] = useState<Scope>('root');
	const [viaCommand, setViaCommand] = useState(false);
	const [active, setActive] = useState(0);
	const [fromHome, setFromHome] = useState(false);
	const [homePage, setHomePage] = useState<'modules' | 'activity'>('modules');
	const [dropHot, setDropHot] = useState(false);
	const [timer, setTimer] = useState<TimerState>({ phase: 'off' });
	const [convert, setConvert] = useState<ConvertState>({ phase: 'off' });
	const [outputs, setOutputs] = useState<string[]>([]);
	const [focusSignal, setFocusSignal] = useState(0);
	const [toast, setToast] = useState<{ id: number; text: string } | null>(null);

	const agent = useAgent(inView);
	const now = useNow(convert.phase === 'running' ? 50 : timer.phase === 'running' ? 250 : null);

	// Drag proximity drives a continuous swell through a motion value, not React state.
	const swell = useMotionValue(0);
	const swellScale = useSpring(useTransform(swell, [0, 1], [1, 1.12]), { stiffness: 420, damping: 40 });

	useEffect(() => {
		const el = stageRef.current;
		if (!el) return;
		const ro = new ResizeObserver(([entry]) => setStageW(entry.contentRect.width));
		ro.observe(el);
		return () => ro.disconnect();
	}, []);

	// Timer and conversion lifecycles: finish, then leave the slot after 8 s like every activity.
	useEffect(() => {
		if (timer.phase === 'running' && now >= timer.endsAt) setTimer({ phase: 'done', label: timer.label, at: now });
		if (timer.phase === 'done' && now - timer.at > DISMISS_MS) setTimer({ phase: 'off' });
		if (convert.phase === 'running' && now - convert.startedAt >= CONVERT_MS) {
			setConvert({ phase: 'done', output: convert.output, at: now });
			setOutputs((list) => [convert.output, ...list.filter((n) => n !== convert.output)].slice(0, 2));
		}
	}, [now, timer, convert]);

	useEffect(() => {
		if (convert.phase !== 'done' && timer.phase !== 'done') return;
		const id = window.setTimeout(() => {
			setConvert((c) => (c.phase === 'done' ? { phase: 'off' } : c));
			setTimer((t) => (t.phase === 'done' ? { phase: 'off' } : t));
		}, DISMISS_MS);
		return () => window.clearTimeout(id);
	}, [convert.phase, timer.phase]);

	useEffect(() => {
		if (!toast) return;
		const id = window.setTimeout(() => setToast(null), 1800);
		return () => window.clearTimeout(id);
	}, [toast]);

	const items: ActivityItem[] = [];
	if (!agent.dismissed) {
		const last = agent.lines.at(-1);
		items.push({
			id: 'agent',
			title: 'Claude · api-server',
			tone: agent.status === 'input' ? 'attention' : agent.status,
			detail:
				agent.status === 'input'
					? `Needs input: ${last?.text ?? ''}`
					: agent.status === 'done'
						? 'Done'
						: agent.status === 'failed'
							? 'Stopped'
							: (last?.text ?? 'Starting'),
		});
	}
	if (timer.phase === 'running' || timer.phase === 'paused') {
		const remaining = timer.phase === 'running' ? timer.endsAt - now : timer.remaining;
		items.push({
			id: 'timer',
			title: timer.label,
			tone: 'running',
			trailing: clock(remaining),
			detail: timer.phase === 'paused' ? 'Paused' : 'Running',
		});
	} else if (timer.phase === 'done') {
		items.push({ id: 'timer', title: timer.label, tone: 'done', detail: 'Finished' });
	}
	if (convert.phase === 'running') {
		items.push({
			id: 'convert',
			title: 'Converting',
			tone: 'running',
			progress: Math.min(1, (now - convert.startedAt) / CONVERT_MS),
			detail: convert.output,
		});
	} else if (convert.phase === 'done') {
		items.push({ id: 'convert', title: 'Converted', tone: 'done', detail: `Saved ${convert.output} next to the original` });
	}
	// Most urgent first. Among equals a conversion leads: it lasts a moment, and the timer is back right after.
	const recency = { convert: 0, timer: 1, agent: 2 };
	items.sort((a, b) => TONE_RANK[a.tone] - TONE_RANK[b.tone] || recency[a.id] - recency[b.id]);
	const lead = items[0];

	// Geometry. The notch shape grows out of the top edge; the island floats under the menu bar.
	const small = stageW < 640;
	const isNotch = display === 'notch';
	const notchW = small ? 150 : 190;
	const notchH = small ? 28 : 32;
	const pad = isNotch ? notchH : 0;
	// Island sits over the menu bar, 5 pt from the top at rest and 6 pt open (NotchModel.ShapeMetrics).
	const top = isNotch ? 0 : surface === 'idle' ? 5 : 6;
	const maxW = stageW - 24;
	let w: number;
	let h: number;
	switch (surface) {
		case 'idle':
			// Island: NotchGeometry.islandSize 56×28, islandCompactSize 250×28 with an activity.
			w = isNotch ? notchW + (lead ? (small ? 84 : 112) : 0) : lead ? (small ? 200 : 250) : 56;
			h = isNotch ? notchH : 28;
			break;
		case 'glance':
			w = Math.min(400, maxW);
			h = pad + contentH;
			break;
		case 'home':
			// NotchGeometry.panelWidth
			w = Math.min(480, maxW);
			h = pad + contentH;
			break;
		case 'panel':
			// NotchGeometry.searchPanelWidth, NotchModel.openRowHeight
			w = Math.min(520, maxW);
			h = pad + 64;
			break;
		case 'drop':
			w = Math.min(340, maxW);
			h = pad + 68;
			break;
		case 'convert':
			w = Math.min(small ? 360 : 480, maxW);
			h = pad + contentH;
			break;
	}
	const rBottom =
		surface === 'idle' ? (isNotch ? (small ? 10 : 12) : h / 2) : surface === 'panel' ? (isNotch ? 22 : h / 2) : 24;
	const rTop = isNotch ? 0 : rBottom;
	// Share of the open search surface that stays solid black: the hardware notch, or the island's top 40%.
	const solidPct = isNotch ? Math.round((pad / h) * 100) : 40;
	const contentPad = surface === 'idle' ? 0 : pad;
	const open = surface === 'home' || surface === 'panel' || surface === 'convert';

	// React 19 ref cleanup disconnects the observer when the content leaves.
	const measure = useCallback((node: HTMLDivElement | null) => {
		if (!node) return;
		setContentH(node.offsetHeight);
		const ro = new ResizeObserver(() => setContentH(node.offsetHeight));
		ro.observe(node);
		return () => ro.disconnect();
	}, []);

	const focusIsland = () => requestAnimationFrame(() => islandRef.current?.focus({ preventScroll: true }));

	const close = () => {
		const hadFocus = islandRef.current?.contains(document.activeElement);
		setSurface('idle');
		setHomePage('modules');
		setQuery('');
		setScope('root');
		setViaCommand(false);
		if (hadFocus) requestAnimationFrame(() => triggerRef.current?.focus({ preventScroll: true }));
	};

	const openHome = () => {
		window.clearTimeout(hoverTimer.current);
		setSurface('home');
		focusIsland();
	};

	const openPanel = (nextScope: Scope, initial: string, home: boolean) => {
		setScope(nextScope);
		setViaCommand(false);
		setQuery(initial);
		setActive(0);
		setFromHome(home);
		setSurface('panel');
		requestAnimationFrame(() => inputRef.current?.focus({ preventScroll: true }));
	};

	const back = () => {
		if (query) {
			setQuery('');
			setActive(0);
		} else if (scope === 'clipboard' && viaCommand) {
			setScope('root');
			setViaCommand(false);
		} else if (fromHome) {
			setSurface('home');
			focusIsland();
		} else {
			close();
		}
	};

	const startTimer = (label: string, minutes: number) =>
		setTimer({ phase: 'running', label, total: minutes * 60_000, endsAt: Date.now() + minutes * 60_000 });

	const toggleTimer = () =>
		setTimer((t) =>
			t.phase === 'running'
				? { phase: 'paused', label: t.label, total: t.total, remaining: t.endsAt - Date.now() }
				: t.phase === 'paused'
					? { phase: 'running', label: t.label, total: t.total, endsAt: Date.now() + t.remaining }
					: t,
		);

	const say = (text: string) => setToast({ id: Date.now(), text });

	const run = (r: Result) => {
		if (r.opensClipboard) {
			setScope('clipboard');
			setViaCommand(true);
			setQuery('');
			setActive(0);
			return;
		}
		if (r.kind === 'timer' && r.minutes) {
			startTimer(`${r.minutes} min timer`, r.minutes);
			say(`${r.minutes} min timer started`);
		} else if (r.kind === 'answer') {
			navigator.clipboard?.writeText(r.title).catch(() => undefined);
			say(`Copied ${r.title}`);
		} else if (r.kind === 'clip') say('Pasted into the front app');
		else if (r.kind === 'setting') say(`Opens ${r.title} in System Settings`);
		else if (r.kind === 'web') say('Opens your default browser');
		else say(`Opens ${r.title}`);
		close();
	};

	const sections = buildSections(query);
	const flat = sections.flatMap((s) => s.rows);
	const clips = filterClips(query);
	const count = scope === 'clipboard' ? clips.length : flat.length;
	const activeIndex = Math.min(active, Math.max(0, count - 1));
	const escapeTitle = scope === 'clipboard' && viaCommand ? 'Back' : fromHome ? 'Home' : 'Close';

	const pasteClip = (clip: Clip) => {
		say(clip.type === 'Image' ? 'Pasted the image into the front app' : 'Pasted into the front app');
		close();
	};

	const copyClip = (clip: Clip) => {
		if (clip.type !== 'Image') navigator.clipboard?.writeText(clip.body).catch(() => undefined);
		say('Copied');
		close();
	};

	const onInputKey = (e: KeyboardEvent<HTMLInputElement>) => {
		if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
			e.preventDefault();
			const step = e.key === 'ArrowDown' ? 1 : -1;
			setActive(Math.max(0, Math.min(count - 1, activeIndex + step)));
		} else if (e.key === 'Enter') {
			e.preventDefault();
			if (scope === 'clipboard') {
				const clip = clips[activeIndex];
				if (clip) (e.metaKey ? copyClip : pasteClip)(clip);
			} else {
				const r = flat[activeIndex];
				if (r) run(r);
			}
		} else if (e.key === 'Escape') {
			e.preventDefault();
			e.stopPropagation();
			back();
		} else if (e.key === 'Backspace' && !query && scope === 'clipboard' && viaCommand) {
			setScope('root');
			setViaCommand(false);
			setActive(0);
		}
	};

	const onStageKey = (e: KeyboardEvent<HTMLDivElement>) => {
		if (e.key === 'Escape' && surface === 'home' && homePage === 'activity') {
			e.preventDefault();
			setHomePage('modules');
			focusIsland();
			return;
		}
		if (e.key === 'Escape' && surface !== 'idle') {
			e.preventDefault();
			close();
			return;
		}
		const typed = e.key.length === 1 && e.key !== ' ' && !e.metaKey && !e.ctrlKey && !e.altKey;
		if (surface === 'home' && typed) {
			e.preventDefault();
			openPanel('root', e.key, true);
		}
	};

	// ⌥Space, the suggested global hotkey, works whenever the demo is on screen, and the on-screen caps mirror
	// the physical keys. One listener reads the latest handler through a ref: re-subscribing on every render
	// would drop the Space keydown, because the Option keydown's state update re-runs effects mid-dispatch.
	const [held, setHeld] = useState({ alt: false, space: false });
	const onHotkey = useRef(() => {});
	onHotkey.current = () => {
		if (surface === 'panel') back();
		else openPanel('root', '', surface === 'home');
	};
	useEffect(() => {
		if (!inView) return;
		const onKey = (e: globalThis.KeyboardEvent) => {
			const space = e.code === 'Space' ? e.type === 'keydown' : undefined;
			setHeld((h) => {
				const next = { alt: e.altKey, space: space ?? (e.altKey ? h.space : false) };
				return next.alt === h.alt && next.space === h.space ? h : next;
			});
			if (e.type !== 'keydown' || !e.altKey || e.code !== 'Space' || e.repeat) return;
			const target = e.target as HTMLElement | null;
			if (target?.closest('input, textarea, [contenteditable]') && target.id !== 'perch-demo-q') return;
			e.preventDefault();
			onHotkey.current();
		};
		const reset = () => setHeld({ alt: false, space: false });
		window.addEventListener('keydown', onKey);
		window.addEventListener('keyup', onKey);
		window.addEventListener('blur', reset);
		return () => {
			window.removeEventListener('keydown', onKey);
			window.removeEventListener('keyup', onKey);
			window.removeEventListener('blur', reset);
			reset();
		};
	}, [inView]);

	const onConvertPick = (action: ConvertAction) => {
		setConvert({ phase: 'running', output: `${SOURCE_FILE.base}${action.suffix}.${action.ext}`, startedAt: Date.now() });
		close();
	};

	const focusAgent = () => {
		setFocusSignal((n) => n + 1);
		setSurface('idle');
	};

	let content = null;
	switch (surface) {
		case 'idle':
			content = lead ? <CompactView item={lead} display={display} height={h} /> : null;
			break;
		case 'glance':
			content = <GlanceView items={items} timer={timer} onFocusAgent={focusAgent} onToggleTimer={toggleTimer} />;
			break;
		case 'home':
			// HomeView.swift: 16 pt sides and bottom; 8 pt under the notch, 14 pt on the island.
			content = (
				<div className="px-4 pb-4" style={{ paddingTop: isNotch ? 8 : 14 }}>
					{homePage === 'activity' ? (
						<ActivityPage
							items={items}
							timer={timer}
							onFocusAgent={focusAgent}
							onToggleTimer={toggleTimer}
							onBack={() => {
								setHomePage('modules');
								focusIsland();
							}}
						/>
					) : (
						<HomeView
							items={items}
							timer={timer}
							now={now}
							convert={convert}
							onFocusAgent={focusAgent}
							onToggleTimer={toggleTimer}
							onStartTimer={startTimer}
							onOpenSearch={(target) => openPanel(target === 'clipboard' ? 'clipboard' : 'root', '', true)}
							onOpenActivity={() => {
								setHomePage('activity');
								focusIsland();
							}}
							onSettings={() => say('Opens Perch Settings')}
						/>
					)}
				</div>
			);
			break;
		case 'panel':
			content = (
				<SearchRow
					query={query}
					scope={scope}
					onQuery={(q) => {
						setQuery(q);
						setActive(0);
					}}
					onKeyDown={onInputKey}
					inputRef={inputRef}
					selected={scope === 'root' ? flat[activeIndex] : undefined}
					activeId={scope === 'clipboard' ? clips[activeIndex]?.id : flat[activeIndex]?.id}
				/>
			);
			break;
		case 'drop':
			content = <DropView hot={dropHot} height={68} />;
			break;
		case 'convert':
			content = <ConvertView onPick={onConvertPick} onCancel={close} />;
			break;
	}

	const shadow =
		surface === 'idle'
			? lead?.tone === 'attention'
				? '0 0 0 1.5px rgb(255 159 10 / 0.75), 0 8px 24px -8px rgb(255 159 10 / 0.45)'
				: '0 0 0 0px rgb(255 159 10 / 0), 0 0 0 0 rgb(0 0 0 / 0)'
			: '0 0 0 0px rgb(255 159 10 / 0), 0 24px 60px -12px rgb(0 0 0 / 0.65)';

	const shapeName = isNotch ? 'notch' : 'island';

	return (
		<div>
			<div
				ref={stageRef}
				role="region"
				aria-label="Interactive Perch demo"
				aria-describedby="perch-demo-hint"
				onKeyDown={onStageKey}
				className="relative h-[640px] overflow-hidden rounded-[22px] border border-line bg-[radial-gradient(120%_80%_at_50%_125%,rgb(255_140_0/0.38),transparent_60%),radial-gradient(60%_50%_at_88%_8%,rgb(255_190_90/0.12),transparent_70%),linear-gradient(180deg,#1b1b1e,#0d0d0f)] sm:h-[600px]"
			>
				<MenuBar display={display} compact={small} />

				<Terminal
					lines={agent.lines}
					status={agent.status}
					focusSignal={focusSignal}
					compact={small}
					onAllow={() => agent.dispatch({ type: 'allow' })}
					onDeny={() => agent.dispatch({ type: 'deny' })}
					onRestart={() => agent.dispatch({ type: 'restart' })}
				/>

				<HotkeyKeys
					visible={surface === 'idle' || surface === 'glance'}
					altDown={held.alt}
					spaceDown={held.alt && held.space}
					className={small ? 'top-[262px]' : 'top-[150px]'}
					onTrigger={() => openPanel('root', '', false)}
				/>

				<DraggableFile
					name={`${SOURCE_FILE.base}.${SOURCE_FILE.ext}`}
					className={small ? 'top-[92px] right-3' : 'top-[112px] right-8'}
					dropRect={() => islandRef.current?.getBoundingClientRect() ?? null}
					onDragStart={() => {
						window.clearTimeout(hoverTimer.current);
						setQuery('');
						setSurface('drop');
					}}
					onDragMove={(hot, distance) => {
						swell.set(reduce ? 0 : Math.max(0, Math.min(1, 1 - distance / 320)));
						if (hot !== dropHotRef.current) {
							dropHotRef.current = hot;
							setDropHot(hot);
						}
					}}
					onDrop={() => {
						swell.set(0);
						dropHotRef.current = false;
						setDropHot(false);
						setSurface('convert');
						focusIsland();
					}}
					onCancel={() => {
						swell.set(0);
						dropHotRef.current = false;
						setDropHot(false);
						setSurface('idle');
					}}
				/>

				<AnimatePresence initial={false}>
					{outputs.map((name, i) => (
						<motion.div
							key={name}
							aria-hidden
							className={`absolute z-[4] flex w-[92px] flex-col items-center gap-1.5 p-1.5 ${small ? 'right-3' : 'right-8'}`}
							style={{ top: (small ? 92 : 112) + (i + 1) * 100 }}
							initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.6 }}
							animate={{ opacity: 1, scale: 1, transition: { type: 'spring', bounce: 0.2, duration: 0.45 } }}
							exit={{ opacity: 0, transition: { duration: 0.15 } }}
						>
							<FileThumb />
							<span className="max-w-full rounded-[4px] bg-black/35 px-1 text-center text-[11px] leading-tight font-medium break-all text-white">
								{name}
							</span>
						</motion.div>
					))}
				</AnimatePresence>

				<AnimatePresence>
					{open && (
						<motion.div
							key="scrim"
							aria-hidden
							className={`absolute inset-0 z-20 ${surface === 'panel' ? '' : 'bg-black/30'}`}
							initial={{ opacity: 0 }}
							animate={{ opacity: 1, transition: { duration: 0.25 } }}
							exit={{ opacity: 0, transition: { duration: 0.2 } }}
							onPointerDown={close}
						/>
					)}
				</AnimatePresence>

				<motion.div
					ref={islandRef}
					tabIndex={-1}
					aria-label={`Perch ${shapeName}`}
					className="absolute left-1/2 z-30 overflow-hidden outline-none"
					style={{ x: '-50%', scale: swellScale, originY: 0 }}
					initial={false}
					animate={{
						width: w,
						height: h,
						top,
						borderTopLeftRadius: rTop,
						borderTopRightRadius: rTop,
						borderBottomLeftRadius: rBottom,
						borderBottomRightRadius: rBottom,
						boxShadow: surface === 'panel' ? '0 0 0 0px rgb(255 159 10 / 0), 0 0 0 0 rgb(0 0 0 / 0)' : shadow,
						backgroundColor: surface === 'panel' ? 'rgba(0,0,0,0)' : 'rgba(0,0,0,1)',
					}}
					transition={reduce ? { duration: 0 } : surface === 'idle' ? SPRING_CLOSE : SPRING_OPEN}
					onPointerEnter={(e) => {
						if (e.pointerType !== 'mouse' || surface !== 'idle' || items.length === 0) return;
						hoverTimer.current = window.setTimeout(() => setSurface('glance'), 60);
					}}
					onPointerLeave={() => {
						window.clearTimeout(hoverTimer.current);
						if (surface === 'glance') setSurface('idle');
					}}
				>
					{/*
					  Open search: frosted glass under a gradient that stays black over the notch (or the top 40% of the
					  island) and fades to clear at the bottom, with a hairline tracing the faded edge (NotchSurface).
					*/}
					<AnimatePresence initial={false}>
						{surface === 'panel' && (
							<motion.div
								key="frost"
								aria-hidden
								className="absolute inset-0 rounded-[inherit] backdrop-blur-[30px] backdrop-saturate-[1.8]"
								style={{
									background: `linear-gradient(to bottom, #000 0%, #000 ${solidPct}%, rgb(0 0 0 / 0.5) ${(solidPct + 100) / 2}%, rgb(0 0 0 / 0) 100%), rgb(58 50 48 / 0.55)`,
								}}
								initial={{ opacity: 0 }}
								animate={{ opacity: 1, transition: { duration: 0.3 } }}
								exit={{ opacity: 0, transition: { duration: 0.2 } }}
							>
								<span
									className="absolute inset-0 rounded-[inherit] border border-white/30"
									style={{
										maskImage: `linear-gradient(to bottom, transparent ${solidPct}%, #000 100%)`,
										WebkitMaskImage: `linear-gradient(to bottom, transparent ${solidPct}%, #000 100%)`,
									}}
								/>
							</motion.div>
						)}
					</AnimatePresence>
					{(surface === 'idle' || surface === 'glance') && (
						<button
							ref={triggerRef}
							type="button"
							onClick={openHome}
							aria-label={`Open Perch${lead ? `. ${lead.title}: ${lead.detail}` : ''}`}
							className="absolute inset-0 cursor-pointer rounded-[inherit] focus-visible:outline-offset-[-3px]"
						/>
					)}
					<AnimatePresence initial={false}>
						{content && (
							<motion.div
								key={`${surface}-${display}-${surface === 'home' ? homePage : ''}`}
								className={`absolute top-0 left-1/2 ${surface === 'idle' || surface === 'glance' ? 'pointer-events-none' : ''}`}
								style={{ width: w, x: '-50%', paddingTop: contentPad }}
								initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.94, filter: 'blur(4px)' }}
								animate={{
									opacity: 1,
									scale: 1,
									filter: 'blur(0px)',
									transition: reduce
										? { duration: 0.15 }
										: { duration: 0.4, ease: [0.32, 0.72, 0, 1], delay: surface === 'idle' ? 0.1 : 0.12 },
								}}
								exit={
									reduce
										? { opacity: 0, transition: { duration: 0.1 } }
										: { opacity: 0, scale: 0.94, filter: 'blur(4px)', transition: { duration: 0.16 } }
								}
							>
								<div ref={measure}>{content}</div>
							</motion.div>
						)}
					</AnimatePresence>
				</motion.div>

				<AnimatePresence>
					{surface === 'panel' && (
						scope === 'clipboard' ? (
							<ClipboardPanel
								key="clipboard"
								top={top + h + 10}
								width={w}
								clips={clips}
								active={activeIndex}
								query={query}
								compact={small}
								onHover={setActive}
								onPaste={pasteClip}
								onCopy={copyClip}
								onClear={() => say('Clears history. Pinned clips stay.')}
							/>
						) : (
							<ResultsPanel
								key="results"
								top={top + h + 10}
								width={w}
								sections={sections}
								active={activeIndex}
								query={query}
								escapeTitle={escapeTitle}
								onHover={setActive}
								onRun={run}
							/>
						)
					)}
				</AnimatePresence>

				<div aria-live="polite" className="pointer-events-none absolute inset-x-0 bottom-6 z-40 flex justify-center">
					<AnimatePresence>
						{toast && (
							<motion.p
								key={toast.id}
								className="material rounded-full border border-white/10 px-4 py-2 text-[13px] font-medium text-white"
								initial={reduce ? { opacity: 0 } : { opacity: 0, y: 12, scale: 0.96 }}
								animate={{ opacity: 1, y: 0, scale: 1, transition: { type: 'spring', bounce: 0, duration: 0.35 } }}
								exit={{ opacity: 0, transition: { duration: 0.15 } }}
							>
								{toast.text}
							</motion.p>
						)}
					</AnimatePresence>
				</div>
			</div>

			<div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
				<div role="group" aria-label="Display" className="inline-flex self-start rounded-full border border-line bg-white/[0.04] p-1">
					{(
						[
							['notch', 'MacBook notch'],
							['island', 'External display'],
						] as const
					).map(([id, label]) => (
						<button
							key={id}
							type="button"
							aria-pressed={display === id}
							onClick={() => {
								setDisplay(id);
								close();
							}}
							className={`press h-9 rounded-full px-4 text-[13px] font-medium ${
								display === id ? 'bg-fg text-canvas' : 'text-fg-2 hover:text-fg'
							}`}
						>
							{label}
						</button>
					))}
				</div>
				<p id="perch-demo-hint" className="text-[14px] text-fg-2">
					Press <kbd className="rounded-md border border-line px-1.5 py-0.5 font-mono text-[12px] text-fg">⌥ Space</kbd>{' '}
					anywhere on the page. Hover the {shapeName} to peek, drag the screenshot onto it to convert.
				</p>
			</div>
		</div>
	);
}
