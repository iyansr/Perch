import { AppleLogoIcon, BatteryHighIcon, WifiHighIcon } from '@phosphor-icons/react';
import { animate, motion, useMotionValue, useReducedMotion } from 'motion/react';
import { useEffect, useRef, useState } from 'react';
import { AGENT_PROMPT } from './data';
import type { Display } from './model';
import type { AgentLine, AgentStatus } from './useAgent';

export function MenuBar({ display, compact }: { display: Display; compact: boolean }) {
	const [time, setTime] = useState('');
	useEffect(() => {
		const fmt = new Intl.DateTimeFormat('en-GB', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
		const tick = () => setTime(fmt.format(new Date()).replace(',', ''));
		tick();
		const id = window.setInterval(tick, 15_000);
		return () => window.clearInterval(id);
	}, []);

	return (
		<div
			aria-hidden
			className="absolute inset-x-0 top-0 z-10 flex h-7 items-center justify-between bg-black/30 px-4 text-[12.5px] text-white/90 backdrop-blur-xl"
		>
			<div className="flex items-center gap-4">
				<AppleLogoIcon size={14} weight="fill" />
				<span className="font-semibold">Finder</span>
				{!compact && (
					<>
						<span>File</span>
						<span>Edit</span>
						<span>View</span>
						<span>Go</span>
						{display === 'island' && <span>Window</span>}
					</>
				)}
			</div>
			<div className="flex items-center gap-3.5">
				<WifiHighIcon size={15} weight="bold" />
				<BatteryHighIcon size={18} />
				{!compact && <span className="tabular-nums">{time}</span>}
			</div>
		</div>
	);
}

const LINE_TONE: Record<AgentLine['kind'], string> = {
	tool: 'text-white/70',
	ask: 'text-white',
	out: 'text-white/55',
	done: 'text-white',
	note: 'text-white/55',
};

export function Terminal({
	lines,
	status,
	focusSignal,
	compact,
	onAllow,
	onDeny,
	onRestart,
}: {
	lines: AgentLine[];
	status: AgentStatus;
	focusSignal: number;
	compact: boolean;
	onAllow: () => void;
	onDeny: () => void;
	onRestart: () => void;
}) {
	const ref = useRef<HTMLDivElement>(null);
	const body = useRef<HTMLDivElement>(null);
	const allow = useRef<HTMLButtonElement>(null);
	const reduce = useReducedMotion();

	useEffect(() => {
		body.current?.scrollTo({ top: body.current.scrollHeight, behavior: reduce ? 'auto' : 'smooth' });
	}, [lines.length, status, reduce]);

	// "Focus" from the notch brings this window forward: a short lift, then keyboard focus on the answer.
	useEffect(() => {
		if (!focusSignal || !ref.current) return;
		if (!reduce) animate(ref.current, { scale: [1, 1.025, 1] }, { duration: 0.4, ease: [0.32, 0.72, 0, 1] });
		allow.current?.focus({ preventScroll: true });
	}, [focusSignal, reduce]);

	const pending = lines.at(-1)?.kind === 'ask' && status === 'input';

	return (
		<div
			ref={ref}
			className={`absolute z-[5] flex flex-col overflow-hidden rounded-[12px] border border-white/10 bg-[#121214]/95 shadow-[0_24px_60px_-16px_rgb(0_0_0/0.7)] ${
				compact ? 'inset-x-3 bottom-3 h-[208px]' : 'bottom-6 left-6 h-[270px] w-[min(460px,52%)]'
			}`}
		>
			<div className="flex h-8 shrink-0 items-center gap-2 border-b border-white/[0.06] px-3">
				<span className="size-3 rounded-full bg-[#ff5f57]" />
				<span className="size-3 rounded-full bg-[#febc2e]" />
				<span className="size-3 rounded-full bg-[#28c840]" />
				<span className="flex-1 truncate pr-10 text-center text-[12px] font-medium text-white/60">claude · api-server</span>
			</div>
			<div ref={body} className="flex-1 space-y-1.5 overflow-y-auto px-3.5 py-3 font-mono text-[12px] leading-relaxed">
				<p className="text-white">
					<span className="text-accent">&gt;</span> {AGENT_PROMPT}
				</p>
				{lines.map((line) =>
					line.kind === 'ask' ? (
						<div key={line.id} className="rounded-lg border border-accent/50 p-2.5">
							<p className="text-white">Allow {line.text}?</p>
							{pending && (
								<div className="mt-2 flex gap-2 font-sans">
									<button
										ref={allow}
										type="button"
										onClick={onAllow}
										className="press h-7 rounded-full bg-accent px-3 text-[12px] font-semibold text-accent-ink"
									>
										Yes, allow
									</button>
									<button
										type="button"
										onClick={onDeny}
										className="press h-7 rounded-full bg-white/10 px-3 text-[12px] font-semibold text-white hover:bg-white/15"
									>
										No
									</button>
								</div>
							)}
						</div>
					) : (
						<p key={line.id} className={LINE_TONE[line.kind]}>
							{line.kind === 'tool' && <span className="text-white/40">● </span>}
							{line.kind === 'out' && <span className="text-white/40">  ⎿ </span>}
							{line.text}
						</p>
					),
				)}
				{status === 'running' && <p className="animate-pulse text-white/45 motion-reduce:animate-none">Working…</p>}
				{(status === 'done' || status === 'failed') && (
					<button
						type="button"
						onClick={onRestart}
						className="press mt-1 h-7 rounded-full bg-white/10 px-3 font-sans text-[12px] font-semibold text-white hover:bg-white/15"
					>
						Run again
					</button>
				)}
			</div>
		</div>
	);
}

/** Apple's projection: where a flick would come to rest (Designing Fluid Interfaces, WWDC 2018). */
function project(velocity: number, decelerationRate = 0.99) {
	return ((velocity / 1000) * decelerationRate) / (1 - decelerationRate);
}

type Sample = { x: number; y: number; t: number };

export function DraggableFile({
	name,
	dropRect,
	onDragStart,
	onDragMove,
	onDrop,
	onCancel,
	className,
}: {
	name: string;
	dropRect: () => DOMRect | null;
	onDragStart: () => void;
	onDragMove: (hot: boolean, distance: number) => void;
	onDrop: () => void;
	onCancel: () => void;
	className: string;
}) {
	const x = useMotionValue(0);
	const y = useMotionValue(0);
	const scale = useMotionValue(1);
	const opacity = useMotionValue(1);
	const reduce = useReducedMotion();
	const el = useRef<HTMLButtonElement>(null);
	const drag = useRef<{ id: number; origin: Sample; samples: Sample[]; active: boolean } | null>(null);

	const inside = (px: number, py: number) => {
		const r = dropRect();
		// 32 px of slack around the drop zone, like the app's drop band.
		return !!r && px > r.left - 32 && px < r.right + 32 && py < r.bottom + 32;
	};

	const distanceTo = (px: number, py: number) => {
		const r = dropRect();
		return r ? Math.hypot(px - (r.left + r.width / 2), py - r.bottom) : Infinity;
	};

	// The drag image flies into the notch and the file reappears in place: the original is never moved.
	const land = () => {
		const r = dropRect();
		const own = el.current?.getBoundingClientRect();
		if (r && own && !reduce) {
			const fly = { type: 'spring', bounce: 0, duration: 0.3 } as const;
			animate(x, x.get() + r.left + r.width / 2 - (own.left + own.width / 2), fly);
			animate(y, y.get() + r.top + r.height / 2 - (own.top + own.height / 2), fly);
		}
		animate(scale, 0.25, { duration: 0.22 });
		animate(opacity, 0, { duration: 0.22 }).then(() => {
			x.jump(0);
			y.jump(0);
			animate(scale, 1, { duration: 0.25 });
			animate(opacity, 1, { duration: 0.25 });
		});
		onDrop();
	};

	return (
		<motion.button
			ref={el}
			type="button"
			aria-label={`${name}. Drag it onto the notch, or press Enter to drop it there.`}
			className={`absolute z-[6] flex w-[92px] cursor-grab touch-none flex-col items-center gap-1.5 rounded-[10px] p-1.5 select-none active:cursor-grabbing ${className}`}
			style={{ x, y, scale, opacity }}
			onKeyDown={(e) => {
				if (e.key === 'Enter' || e.key === ' ') {
					e.preventDefault();
					onDrop();
				}
			}}
			onPointerDown={(e) => {
				if (e.button !== 0) return;
				e.currentTarget.setPointerCapture(e.pointerId);
				// Grab from where the pointer is: the delta keeps the grab offset, no snap to centre.
				const start = { x: e.clientX - x.get(), y: e.clientY - y.get(), t: e.timeStamp };
				drag.current = { id: e.pointerId, origin: start, samples: [{ x: e.clientX, y: e.clientY, t: e.timeStamp }], active: false };
				x.stop();
				y.stop();
				animate(scale, 1.06, { type: 'spring', bounce: 0, duration: 0.25 });
			}}
			onPointerMove={(e) => {
				const d = drag.current;
				if (!d || d.id !== e.pointerId) return;
				const dx = e.clientX - d.origin.x;
				const dy = e.clientY - d.origin.y;
				if (!d.active && Math.hypot(dx - x.get(), dy - y.get()) < 4) return;
				if (!d.active) {
					d.active = true;
					onDragStart();
				}
				x.set(dx);
				y.set(dy);
				d.samples = [...d.samples.slice(-5), { x: e.clientX, y: e.clientY, t: e.timeStamp }];
				onDragMove(inside(e.clientX, e.clientY), distanceTo(e.clientX, e.clientY));
			}}
			onPointerUp={(e) => {
				const d = drag.current;
				drag.current = null;
				if (!d || d.id !== e.pointerId) return;
				if (!d.active) {
					animate(scale, 1, { type: 'spring', bounce: 0, duration: 0.25 });
					return;
				}
				const first = d.samples[0];
				const last = d.samples.at(-1) ?? first;
				const dt = Math.max(1, last.t - first.t);
				const vx = ((last.x - first.x) / dt) * 1000;
				const vy = ((last.y - first.y) / dt) * 1000;
				// A flick toward the notch counts: test where the motion would come to rest, not just the release point.
				if (inside(e.clientX, e.clientY) || inside(e.clientX + project(vx), e.clientY + project(vy))) {
					land();
					return;
				}
				onCancel();
				const back = reduce
					? { duration: 0 }
					: ({ type: 'spring', bounce: 0.2, duration: 0.45 } as const);
				animate(x, 0, { ...back, velocity: vx });
				animate(y, 0, { ...back, velocity: vy });
				animate(scale, 1, { type: 'spring', bounce: 0, duration: 0.3 });
			}}
			onPointerCancel={() => {
				drag.current = null;
				onCancel();
				animate(x, 0, { type: 'spring', bounce: 0, duration: 0.4 });
				animate(y, 0, { type: 'spring', bounce: 0, duration: 0.4 });
				animate(scale, 1, { duration: 0.2 });
			}}
		>
			<FileThumb />
			<span className="rounded-[4px] bg-black/35 px-1 text-[11px] leading-tight font-medium text-white">{name}</span>
		</motion.button>
	);
}

export function FileThumb() {
	return (
		<span
			aria-hidden
			className="block h-[54px] w-[64px] rounded-[6px] border-[3px] border-white bg-[linear-gradient(160deg,#ffcf70,#ff7a1a_55%,#3b2a1f)] shadow-[0_6px_16px_-6px_rgb(0_0_0/0.6)]"
		/>
	);
}
