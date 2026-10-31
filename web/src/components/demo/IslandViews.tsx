import {
	ArrowDownIcon,
	CaretLeftIcon,
	CheckIcon,
	ClipboardTextIcon,
	CloudSunIcon,
	CopyIcon,
	FileArrowDownIcon,
	GearSixIcon,
	HeadphonesIcon,
	HouseIcon,
	ImageSquareIcon,
	MagnifyingGlassIcon,
	MouseIcon,
	MusicNotesIcon,
	PauseIcon,
	PlayIcon,
	SkipBackIcon,
	SkipForwardIcon,
	TerminalWindowIcon,
	TimerIcon,
	VideoCameraIcon,
	XIcon,
} from '@phosphor-icons/react';
import { useEffect, useState, type ReactNode } from 'react';
import { CLIPS, CONVERT_ACTIONS, DEVICES, MEETING, OTHER_AGENTS, SOURCE_FILE, TRACK, WEATHER, type ConvertAction } from './data';
import type { ActivityItem, ConvertState, Display, HomePage, TimerState } from './model';
import { clock } from './model';

export function Glyph({ id, size = 16 }: { id: ActivityItem['id']; size?: number }) {
	if (id === 'agent') {
		return (
			<span
				aria-hidden
				className="inline-block shrink-0 bg-[#d97757]"
				style={{
					width: size,
					height: size,
					maskImage: 'url(/brand/ClaudeLogo.svg)',
					WebkitMaskImage: 'url(/brand/ClaudeLogo.svg)',
					maskSize: 'contain',
					WebkitMaskSize: 'contain',
				}}
			/>
		);
	}
	const Icon = id === 'timer' ? TimerIcon : ImageSquareIcon;
	return <Icon aria-hidden size={size} weight="bold" className="shrink-0 text-white" />;
}

export function Ring({ value, size = 16 }: { value: number; size?: number }) {
	const r = size / 2 - 2;
	const c = 2 * Math.PI * r;
	return (
		<svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden className="-rotate-90">
			<circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="rgb(255 255 255 / 0.2)" strokeWidth="2.5" />
			<circle
				cx={size / 2}
				cy={size / 2}
				r={r}
				fill="none"
				stroke="white"
				strokeWidth="2.5"
				strokeLinecap="round"
				strokeDasharray={c}
				strokeDashoffset={c * (1 - value)}
			/>
		</svg>
	);
}

export function StatusMark({ item }: { item: ActivityItem }) {
	if (item.tone === 'attention') {
		return (
			<span className="flex items-center gap-1.5 text-[11px] font-semibold text-accent">
				<span className="size-1.5 rounded-full bg-accent" />
				Input
			</span>
		);
	}
	if (item.tone === 'done') return <CheckIcon aria-hidden size={14} weight="bold" className="text-white" />;
	if (item.tone === 'failed') return <XIcon aria-hidden size={14} weight="bold" className="text-white/70" />;
	if (item.trailing) {
		return <span className="font-mono text-[11px] font-medium tabular-nums text-white/85">{item.trailing}</span>;
	}
	if (item.progress !== undefined) return <Ring value={item.progress} />;
	return (
		<span
			aria-hidden
			className="size-3.5 animate-spin rounded-full border-2 border-white/20 border-t-white motion-reduce:animate-none"
		/>
	);
}

/** Idle pill with a live activity: glyph in the left ear, status in the right one. */
export function CompactView({ item, display, height }: { item: ActivityItem; display: Display; height: number }) {
	return (
		<div className="flex items-center justify-between px-3" style={{ height }}>
			<span className="flex min-w-0 items-center gap-2">
				<Glyph id={item.id} size={15} />
				{display === 'island' && (
					<span className="truncate text-[12px] font-medium text-white/85">{item.title}</span>
				)}
			</span>
			<StatusMark item={item} />
		</div>
	);
}

/** Status tints from ActivityViews.swift: running uses the accent, then orange, green, red. */
const TINT: Record<ActivityItem['tone'], string> = {
	running: 'rgb(255 159 10 / 0.18)',
	attention: 'rgb(255 159 10 / 0.18)',
	done: 'rgb(48 209 88 / 0.18)',
	failed: 'rgb(255 69 58 / 0.18)',
};

/** A full activity row (glance card and the Activity page): 52 px, 30 px tinted glyph, actions on the right. */
function ActivityRow({ item, action }: { item: ActivityItem; action?: ReactNode }) {
	return (
		<div className="flex h-[52px] items-center gap-3">
			<span className="grid size-[30px] shrink-0 place-items-center rounded-full" style={{ background: TINT[item.tone] }}>
				<Glyph id={item.id} size={15} />
			</span>
			<span className="flex min-w-0 flex-1 flex-col gap-0.5">
				<span className="truncate text-[13px] font-semibold text-white">{item.title}</span>
				<span className={`truncate text-[11px] ${item.tone === 'attention' ? 'text-accent' : 'text-white/60'}`}>
					{item.detail}
				</span>
			</span>
			{action ?? <StatusMark item={item} />}
		</div>
	);
}

type RowActions = {
	onFocusAgent: () => void;
	onToggleTimer: () => void;
	timer: TimerState;
};

function rowAction(item: ActivityItem, { onFocusAgent, onToggleTimer, timer }: RowActions) {
	if (item.id === 'agent' && item.tone === 'attention') {
		return (
			<button
				type="button"
				onClick={(e) => {
					e.stopPropagation();
					onFocusAgent();
				}}
				className="press pointer-events-auto h-7 rounded-full bg-accent px-3 text-[12px] font-semibold text-accent-ink"
			>
				Focus
			</button>
		);
	}
	if (item.id === 'timer' && (timer.phase === 'running' || timer.phase === 'paused')) {
		const running = timer.phase === 'running';
		return (
			<button
				type="button"
				aria-label={running ? 'Pause timer' : 'Resume timer'}
				onClick={(e) => {
					e.stopPropagation();
					onToggleTimer();
				}}
				className="press pointer-events-auto grid size-7 place-items-center rounded-full bg-white/[0.12] text-white hover:bg-white/20"
			>
				{running ? <PauseIcon size={13} weight="fill" /> : <PlayIcon size={13} weight="fill" />}
			</button>
		);
	}
	return undefined;
}

export function GlanceView({ items, ...actions }: { items: ActivityItem[] } & RowActions) {
	return (
		<div className="px-4 pb-2">
			{items.map((item) => (
				<ActivityRow key={item.id} item={item} action={rowAction(item, actions)} />
			))}
		</div>
	);
}

/** ModuleHeader: 11 pt semibold title. */
function ModuleHeader({ title, children }: { title: string; children?: ReactNode }) {
	return (
		<span className="flex h-[18px] w-full items-center gap-2">
			<span className="truncate text-[11px] font-semibold text-white/60">{title}</span>
			<span className="flex-1" />
			{children}
		</span>
	);
}

function Note({ children }: { children: ReactNode }) {
	return <span className="mt-1.5 flex w-full flex-wrap items-center gap-1 text-[11px] text-white/40">{children}</span>;
}

/** ModuleCard: 18 px continuous corners, 14×12 padding; dashed when it is a drop well. */
const CARD = 'flex flex-col items-start rounded-[18px] px-3.5 py-3 text-left text-white';
const SOLID = `${CARD} border-[0.5px] border-white/[0.08] bg-white/[0.06]`;
const CHIP = 'press h-[26px] rounded-full bg-white/10 px-2.5 text-[12px] font-medium text-white hover:bg-white/[0.16]';
const ICON_BTN = 'press grid size-7 place-items-center rounded-full text-white/60 hover:bg-white/10 hover:text-white';

/** Search on the left, Settings on the right: the only chrome inside the surface (HomeBar). */
export function HomeBar({ height, onSearch, onSettings }: { height: number; onSearch: () => void; onSettings: () => void }) {
	return (
		<div className="flex items-center justify-between px-3" style={{ height }}>
			<button type="button" onClick={onSearch} aria-label="Search" className={ICON_BTN}>
				<MagnifyingGlassIcon size={14} weight="bold" />
			</button>
			<button type="button" onClick={onSettings} aria-label="Settings" className={ICON_BTN}>
				<GearSixIcon size={14} weight="bold" />
			</button>
		</div>
	);
}

const DOCK_TABS: { id: HomePage; label: string; Icon: typeof HouseIcon }[] = [
	{ id: 'home', label: 'Home', Icon: HouseIcon },
	{ id: 'clipboard', label: 'Clipboard', Icon: ClipboardTextIcon },
	{ id: 'timer', label: 'Timer', Icon: TimerIcon },
	{ id: 'convert', label: 'Convert', Icon: ImageSquareIcon },
];

/** HomeDock: a glass pill under the surface that switches Home pages. 32×24 tabs, 12 pt icons. */
export function HomeDock({ page, onPage }: { page: HomePage; onPage: (page: HomePage) => void }) {
	return (
		<div
			role="tablist"
			aria-label="Home pages"
			className="flex gap-px rounded-full border-[0.5px] border-white/[0.18] bg-black/40 p-[3px] shadow-[0_10px_28px_rgb(0_0_0/0.28)] backdrop-blur-[22px] backdrop-saturate-[1.7]"
		>
			{DOCK_TABS.map(({ id, label, Icon }) => (
				<button
					key={id}
					type="button"
					role="tab"
					aria-selected={page === id}
					aria-label={label}
					title={label}
					onClick={() => onPage(id)}
					className={`press grid h-6 w-8 place-items-center rounded-full transition-colors duration-150 ${
						page === id ? 'bg-white/[0.18] text-white' : 'text-white/55 hover:text-white'
					}`}
				>
					<Icon size={12} weight="bold" />
				</button>
			))}
		</div>
	);
}

type AgentRowData = { id: string; glyph: ReactNode; title: string; status: ActivityItem['tone']; age: string };

const STATUS_LABEL: Record<ActivityItem['tone'], string> = {
	running: 'Running',
	attention: 'Needs input',
	done: 'Done',
	failed: 'Failed',
};
const DOT: Record<ActivityItem['tone'], string> = {
	running: 'bg-accent',
	attention: 'bg-[#ff9f0a]',
	done: 'bg-[#30d158]',
	failed: 'bg-[#ff453a]',
};

type HomeProps = RowActions & {
	items: ActivityItem[];
	now: number;
	/** The live Claude session's pending command, while it waits for an answer. */
	agentAsk?: string;
	onAllow: () => void;
	onDeny: () => void;
	onStartTimer: (label: string, minutes: number) => void;
	onOpenActivity: () => void;
	say: (text: string) => void;
};

/**
 * Mirrors Perch/Notch/Views/HomeView.swift (HomeLanding): agents in the tall tile, music and the next meeting beside
 * it, focus, weather and batteries along the bottom. Other activities sit in a strip on top.
 */
export function HomeView(props: HomeProps) {
	const { items, timer, now, agentAsk, onAllow, onDeny, onFocusAgent, onToggleTimer, onStartTimer, onOpenActivity, say } =
		props;
	const claude = items.find((i) => i.id === 'agent');
	const agents: AgentRowData[] = [
		...(claude
			? [{ id: 'claude', glyph: <Glyph id="agent" size={11} />, title: claude.title, status: claude.tone, age: 'now' }]
			: []),
		...OTHER_AGENTS.map((a) => ({
			id: a.id,
			glyph: <TerminalWindowIcon aria-hidden size={11} weight="bold" className="text-white" />,
			title: a.title,
			status: a.status,
			age: a.age,
		})),
	];
	const waiting = agents.filter((a) => a.status === 'attention').length;
	const working = agents.filter((a) => a.status === 'running').length;
	const strip = items.find((i) => i.id === 'convert');
	const remaining = timer.phase === 'running' ? timer.endsAt - now : timer.phase === 'paused' ? timer.remaining : 25 * 60_000;
	const active = timer.phase === 'running' || timer.phase === 'paused';

	return (
		<div className="flex flex-col gap-2">
			{strip && (
				<div className={`${SOLID} flex-row! items-center gap-3`}>
					<span className="grid size-[30px] shrink-0 place-items-center rounded-full" style={{ background: TINT[strip.tone] }}>
						<Glyph id="convert" size={15} />
					</span>
					<span className="flex min-w-0 flex-1 flex-col">
						<span className="truncate text-[13px] font-semibold">{strip.title}</span>
						<span className="truncate text-[11px] text-white/60">{strip.detail}</span>
					</span>
					<StatusMark item={strip} />
				</div>
			)}

			<div className="grid grid-cols-[1.15fr_1fr] gap-2">
				<div className={`${SOLID} row-span-2`}>
					<ModuleHeader title="Agents">
						{waiting ? (
							<span className="text-[11px] font-semibold text-[#ff9f0a]">{waiting} needs you</span>
						) : working ? (
							<span className="text-[11px] font-semibold text-accent">{working} working</span>
						) : null}
					</ModuleHeader>
					<span className="-mx-1.5 mt-1 flex w-[calc(100%+12px)] flex-col">
						{agents.map((a) => (
							<button
								key={a.id}
								type="button"
								onClick={() => (a.id === 'claude' ? onFocusAgent() : say('Brings the agent’s terminal forward'))}
								className="press flex items-center gap-2 rounded-[10px] px-1.5 py-[5px] text-left transition-colors hover:bg-white/[0.06]"
							>
								<span className="grid size-6 shrink-0 place-items-center rounded-[7px]" style={{ background: TINT[a.status] }}>
									{a.glyph}
								</span>
								<span className="flex min-w-0 flex-1 flex-col">
									<span className="truncate text-[12px] font-semibold">{a.title}</span>
									<span className="truncate text-[11px] text-white/40">
										{STATUS_LABEL[a.status]} · {a.age}
									</span>
								</span>
								<span className={`size-[7px] shrink-0 rounded-full ${DOT[a.status]}`} />
							</button>
						))}
					</span>
					{agentAsk && (
						<div className="mt-auto w-full rounded-[10px] border-[0.5px] border-[#ff9f0a]/30 bg-[#ff9f0a]/[0.12] p-2">
							<p className="line-clamp-2 text-[11px]">
								<b>api-server</b> · <span className="font-mono">{agentAsk}</span>
							</p>
							<span className="mt-1.5 flex justify-end gap-1.5">
								<button type="button" onClick={onDeny} className={CHIP}>
									Deny
								</button>
								<button
									type="button"
									onClick={onAllow}
									className="press h-[26px] rounded-full bg-white px-2.5 text-[12px] font-medium text-black hover:bg-white/85"
								>
									Allow
								</button>
							</span>
						</div>
					)}
				</div>

				<MusicTile />

				<div className={SOLID}>
					<span className="flex h-[18px] items-center gap-1.5 text-[11px] font-semibold text-white/60">
						<VideoCameraIcon aria-hidden size={11} weight="bold" />
						Next
					</span>
					<span className="mt-1 w-full truncate text-[13px] font-semibold">{MEETING.title}</span>
					<span className="mt-1.5 flex w-full items-center gap-1.5">
						<span className="flex-1 truncate text-[11px] text-white/40">
							{MEETING.time} · {MEETING.app}
						</span>
						<button
							type="button"
							onClick={() => say(`Opens ${MEETING.app}`)}
							className="press h-[26px] rounded-full bg-[#30d158] px-2.5 text-[12px] font-medium text-black hover:brightness-110"
						>
							Join
						</button>
					</span>
				</div>
			</div>

			<div className="grid grid-cols-3 gap-2">
				<div className={`${SOLID} flex-row! items-center gap-2`}>
					<Ring value={active && timer.total ? 1 - remaining / timer.total : 0} size={26} />
					<span className="flex min-w-0 flex-1 flex-col">
						<span className="text-[12px] font-semibold tabular-nums">{clock(remaining)}</span>
						<span className="truncate text-[11px] text-white/40">{active ? timer.label : 'Focus'}</span>
					</span>
					<button
						type="button"
						aria-label={!active ? 'Start focus' : timer.phase === 'running' ? 'Pause' : 'Resume'}
						onClick={() => (active ? onToggleTimer() : onStartTimer('Focus', 25))}
						className={ICON_BTN}
					>
						{timer.phase === 'running' ? <PauseIcon size={11} weight="fill" /> : <PlayIcon size={11} weight="fill" />}
					</button>
				</div>
				<button type="button" onClick={() => say('Opens Weather')} className={`${SOLID} press hover:bg-white/10`}>
					<span className="flex h-[18px] items-center gap-1.5">
						<CloudSunIcon aria-hidden size={14} weight="fill" className="text-[#ffd60a]" />
						<span className="text-[13px] font-semibold tabular-nums">{WEATHER.temp}</span>
					</span>
					<span className="mt-0.5 text-[11px] text-white/40">{WEATHER.place}</span>
				</button>
				<div className={`${SOLID} justify-center gap-1`}>
					{DEVICES.map((d) => {
						const Icon = d.name.includes('Mouse') ? MouseIcon : HeadphonesIcon;
						return (
							<span key={d.name} className="flex w-full items-center gap-1.5 text-[11px]">
								<Icon aria-hidden size={11} className="shrink-0 text-white/60" />
								<span className="flex-1 truncate text-white/60">{d.name}</span>
								<span className={`tabular-nums ${d.percent <= 20 ? 'text-[#ff453a]' : ''}`}>{d.percent}%</span>
							</span>
						);
					})}
				</div>
			</div>

			{items.length > 0 && (
				<button type="button" onClick={onOpenActivity} className="self-start text-[11px] text-white/40 hover:text-white/70">
					All activity ({items.length})
				</button>
			)}
		</div>
	);
}

/** MusicTile: artwork, track, waveform, then a slim progress bar and transport. Plays locally. */
function MusicTile() {
	const [playing, setPlaying] = useState(true);
	const [pos, setPos] = useState(6);
	useEffect(() => {
		if (!playing) return;
		const id = window.setInterval(() => setPos((p) => (p + 1) % TRACK.duration), 1000);
		return () => window.clearInterval(id);
	}, [playing]);
	return (
		<div className={SOLID}>
			<span className="flex w-full items-center gap-2.5">
				<span className="size-10 shrink-0 rounded-[9px] bg-[linear-gradient(135deg,#1d3557,#457b9d_50%,#0b132b)] shadow-[inset_0_0_0_0.5px_rgb(255_255_255/0.15)]" />
				<span className="flex min-w-0 flex-1 flex-col">
					<span className="truncate text-[12px] font-semibold">{TRACK.title}</span>
					<span className="truncate text-[11px] text-white/60">{TRACK.artist}</span>
				</span>
				<MusicNotesIcon aria-hidden size={13} className={playing ? 'text-[#7fb3d5]' : 'text-white/30'} />
			</span>
			<span className="mt-2 flex w-full items-center gap-1">
				<span className="relative h-1 flex-1 overflow-hidden rounded-full bg-white/[0.16]">
					<span
						className="absolute inset-0 origin-left bg-white transition-transform duration-1000 ease-linear"
						style={{ transform: `scaleX(${pos / TRACK.duration})` }}
					/>
				</span>
				<button type="button" aria-label="Previous track" onClick={() => setPos(0)} className={ICON_BTN}>
					<SkipBackIcon size={11} weight="fill" />
				</button>
				<button
					type="button"
					aria-label={playing ? 'Pause' : 'Play'}
					onClick={() => setPlaying((p) => !p)}
					className="press grid size-7 place-items-center rounded-full text-white hover:bg-white/10"
				>
					{playing ? <PauseIcon size={13} weight="fill" /> : <PlayIcon size={13} weight="fill" />}
				</button>
				<button type="button" aria-label="Next track" onClick={() => setPos(0)} className={ICON_BTN}>
					<SkipForwardIcon size={11} weight="fill" />
				</button>
			</span>
		</div>
	);
}

/** Clipboard page: the latest clips; a click copies the clip back. */
export function ClipboardPage({ onOpenHistory, say }: { onOpenHistory: () => void; say: (text: string) => void }) {
	const [copied, setCopied] = useState<string | null>(null);
	useEffect(() => {
		if (!copied) return;
		const id = window.setTimeout(() => setCopied(null), 1200);
		return () => window.clearTimeout(id);
	}, [copied]);
	return (
		<div className="flex flex-col gap-2">
			<div className="flex flex-col gap-0.5">
				{CLIPS.slice(0, 4).map((c) => (
					<button
						key={c.id}
						type="button"
						onClick={() => {
							if (c.type !== 'Image') navigator.clipboard?.writeText(c.body).catch(() => undefined);
							setCopied(c.id);
							say('Copied');
						}}
						className="press flex items-center gap-2.5 rounded-[12px] px-2.5 py-1.5 text-left transition-colors hover:bg-white/[0.08]"
					>
						<span className="grid size-7 shrink-0 place-items-center rounded-[8px] bg-white/[0.08] text-white/60">
							{c.type === 'Color' ? (
								<span className="size-3 rounded-[4px]" style={{ background: c.body }} />
							) : (
								<ClipboardTextIcon size={12} />
							)}
						</span>
						<span className="flex min-w-0 flex-1 flex-col">
							<span className={`truncate text-[12px] text-white ${c.type === 'Text' ? 'font-mono' : ''}`}>{c.title}</span>
							<span className="truncate text-[11px] text-white/40">
								{c.source} · {c.copied}
							</span>
						</span>
						{copied === c.id ? (
							<CheckIcon aria-hidden size={12} weight="bold" className="text-[#30d158]" />
						) : (
							<CopyIcon aria-hidden size={12} className="text-white/40" />
						)}
					</button>
				))}
			</div>
			<button type="button" onClick={onOpenHistory} className={`${CHIP} self-end`}>
				Open history ›
			</button>
		</div>
	);
}

/** Timer page: ring and clock with Pause/Cancel, otherwise one-click presets. */
export function TimerPage({
	timer,
	now,
	onStart,
	onToggle,
	onCancel,
}: {
	timer: TimerState;
	now: number;
	onStart: (label: string, minutes: number) => void;
	onToggle: () => void;
	onCancel: () => void;
}) {
	if (timer.phase === 'running' || timer.phase === 'paused') {
		const remaining = timer.phase === 'running' ? timer.endsAt - now : timer.remaining;
		return (
			<div className={`${SOLID} flex-row! items-center gap-5`}>
				<span className="relative grid size-[104px] place-items-center">
					<span className="absolute inset-0">
						<Ring value={timer.total ? 1 - remaining / timer.total : 0} size={104} />
					</span>
					<span
						className={`text-[22px] font-semibold tracking-[-0.4px] tabular-nums ${timer.phase === 'paused' ? 'text-white/60' : ''}`}
					>
						{clock(remaining)}
					</span>
				</span>
				<span className="flex flex-col">
					<span className="text-[11px] font-semibold text-white/60">{timer.label}</span>
					<span className="mt-2.5 flex gap-1.5">
						<button type="button" onClick={onToggle} className={CHIP}>
							{timer.phase === 'running' ? 'Pause' : 'Resume'}
						</button>
						<button type="button" onClick={onCancel} className={CHIP}>
							Cancel
						</button>
					</span>
				</span>
			</div>
		);
	}
	return (
		<div className={SOLID}>
			<ModuleHeader title="Timer" />
			<span className="mt-2 text-[16px] font-semibold">Start a timer</span>
			<span className="mt-3 flex flex-wrap gap-1.5">
				{(
					[
						['5 min', 5],
						['15 min', 15],
						['25 min', 25],
						['Pomodoro', 25],
					] as const
				).map(([label, minutes]) => (
					<button key={label} type="button" onClick={() => onStart(label, minutes)} className={CHIP}>
						{label}
					</button>
				))}
			</span>
		</div>
	);
}

/** Convert page: drop target hint plus the latest conversion; reads as a dashed well. */
export function ConvertPage({ items, convert }: { items: ActivityItem[]; convert: ConvertState }) {
	const conversion = items.find((i) => i.id === 'convert');
	return (
		<div className={`${CARD} min-h-[98px] border border-dashed border-white/20`}>
			<ModuleHeader title="Convert" />
			{conversion ? (
				<span className="mt-2 flex w-full items-center gap-2 text-[12px] font-semibold">
					<Glyph id="convert" size={11} />
					<span className="truncate">{convert.phase === 'done' ? convert.output : conversion.title}</span>
				</span>
			) : (
				<span className="mt-2 text-[13px] font-semibold">Drop an image</span>
			)}
			<Note>
				<FileArrowDownIcon aria-hidden size={12} />
				Drag files onto the notch
			</Note>
		</div>
	);
}

/** Every activity with its actions; esc or "Home" shrinks it back into the Activity module. */
export function ActivityPage({ items, onBack, ...actions }: { items: ActivityItem[]; onBack: () => void } & RowActions) {
	return (
		<div className="flex flex-col">
			<div className="flex h-8 items-center gap-2">
				<button
					type="button"
					onClick={onBack}
					className="press -ml-2 flex h-7 items-center gap-0.5 rounded-full px-2 text-[13px] text-white/80 hover:bg-white/10"
				>
					<CaretLeftIcon aria-hidden size={11} weight="bold" />
					Home
				</button>
				<span className="text-[13px] font-semibold text-white">Activity</span>
				<span className="flex-1" />
				<span className="text-[11px] text-white/40">{items.length === 1 ? '1 item' : `${items.length} items`}</span>
			</div>
			{items.length === 0 ? (
				<p className="py-5 text-center text-[13px] text-white/60">Nothing running</p>
			) : (
				items.map((item) => <ActivityRow key={item.id} item={item} action={rowAction(item, actions)} />)
			)}
		</div>
	);
}

export function DropView({ hot, height }: { hot: boolean; height: number }) {
	return (
		<div className="p-2.5" style={{ height }}>
			<div
				className={`flex h-full items-center justify-center gap-2 rounded-[18px] border-2 border-dashed text-[13px] font-semibold transition-colors ${
					hot ? 'border-accent bg-accent/10 text-accent' : 'border-white/25 text-white/80'
				}`}
			>
				<ArrowDownIcon aria-hidden size={15} weight="bold" />
				{hot ? 'Release to convert' : 'Drop to convert'}
			</div>
		</div>
	);
}

export function ConvertView({ onPick, onCancel }: { onPick: (action: ConvertAction) => void; onCancel: () => void }) {
	return (
		<div className="p-3">
			<div className="flex items-center gap-3 px-1 pb-3">
				<span className="size-9 shrink-0 rounded-[10px] bg-[linear-gradient(160deg,#ffcf70,#ff7a1a_55%,#3b2a1f)]" />
				<span className="flex min-w-0 flex-1 flex-col">
					<span className="truncate text-[13px] font-semibold text-white">
						{SOURCE_FILE.base}.{SOURCE_FILE.ext}
					</span>
					<span className="text-[12px] text-white/60">{SOURCE_FILE.size} · HEIC image</span>
				</span>
				<button
					type="button"
					onClick={onCancel}
					aria-label="Cancel"
					className="press grid size-7 place-items-center rounded-full bg-white/[0.1] text-white/80 hover:bg-white/20"
				>
					<XIcon size={13} weight="bold" />
				</button>
			</div>
			<div className="grid grid-cols-3 gap-1.5 sm:grid-cols-5">
				{CONVERT_ACTIONS.map((action) => (
					<button
						key={action.id}
						type="button"
						onClick={() => onPick(action)}
						className="press h-9 rounded-full bg-white/[0.1] px-3 text-[12px] font-semibold whitespace-nowrap text-white hover:bg-white/[0.18]"
					>
						{action.label}
					</button>
				))}
			</div>
		</div>
	);
}
