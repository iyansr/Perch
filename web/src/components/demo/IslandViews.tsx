import {
	ArrowDownIcon,
	CaretLeftIcon,
	CaretRightIcon,
	CheckIcon,
	FileArrowDownIcon,
	GearSixIcon,
	ImageSquareIcon,
	MagnifyingGlassIcon,
	PauseIcon,
	PlayIcon,
	TimerIcon,
	XIcon,
} from '@phosphor-icons/react';
import type { ReactNode } from 'react';
import { CLIPS, CONVERT_ACTIONS, SOURCE_FILE, type ConvertAction } from './data';
import type { ActivityItem, ConvertState, Display, TimerState } from './model';
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

/** Home's Activity module row: 32 px, 22 px glyph, title and detail on one line. */
function CompactActivityRow({ item }: { item: ActivityItem }) {
	return (
		<span className="flex h-8 items-center gap-2.5">
			<span className="grid size-[22px] shrink-0 place-items-center rounded-full" style={{ background: TINT[item.tone] }}>
				<Glyph id={item.id} size={11} />
			</span>
			<span className="shrink-0 text-[13px] font-semibold text-white">{item.title}</span>
			<span className="min-w-0 flex-1 truncate text-[11px] text-white/60">{item.detail}</span>
			<StatusMark item={item} />
		</span>
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

/** ModuleHeader: 11 pt semibold title, optional badge, chevron when the module opens something. */
function ModuleHeader({ title, badge, chevron }: { title: string; badge?: string; chevron?: boolean }) {
	return (
		<span className="flex h-[18px] w-full items-center gap-2">
			<span className="truncate text-[11px] font-semibold text-white/60">{title}</span>
			{badge && (
				<span className="rounded-full bg-accent/20 px-[7px] py-0.5 text-[11px] font-semibold text-accent">{badge}</span>
			)}
			<span className="flex-1" />
			{chevron && <CaretRightIcon aria-hidden size={11} weight="bold" className="text-white/40" />}
		</span>
	);
}

function Note({ children }: { children: ReactNode }) {
	return <span className="mt-1.5 flex w-full flex-wrap items-center gap-1 text-[11px] text-white/40">{children}</span>;
}

function KeyCap({ children }: { children: ReactNode }) {
	return (
		<kbd className="rounded-[5px] border border-white/15 px-1.5 py-px font-sans text-[11px] text-white/75">{children}</kbd>
	);
}

/** ModuleCard: 18 px continuous corners, 14×12 padding; dashed when it is a drop well. */
const CARD = 'flex flex-col items-start rounded-[18px] px-3.5 py-3 text-left text-white';
const SOLID = `${CARD} border-[0.5px] border-white/[0.08] bg-white/[0.06]`;
/** A whole module as one button: lifts on hover, presses in on mouse-down. */
const BUTTON = `${SOLID} press transition-colors hover:bg-white/10 focus-visible:outline-offset-0`;

type HomeProps = RowActions & {
	items: ActivityItem[];
	now: number;
	convert: ConvertState;
	onStartTimer: (label: string, minutes: number) => void;
	onOpenSearch: (target: 'all' | 'clipboard') => void;
	onOpenActivity: () => void;
	onSettings: () => void;
};

/** Mirrors Perch/Notch/Views/HomeView.swift: Activity across the top, then Timer | Clipboard, Search | Convert. */
export function HomeView(props: HomeProps) {
	const { items, timer, now, convert, onStartTimer, onOpenSearch, onOpenActivity, onSettings, onToggleTimer } = props;
	const remaining = timer.phase === 'running' ? timer.endsAt - now : timer.phase === 'paused' ? timer.remaining : 0;
	const blocked = items.filter((i) => i.tone === 'attention').length;
	const failed = items.filter((i) => i.tone === 'failed').length;
	const badge = blocked ? `${blocked} needs input` : failed ? `${failed} failed` : undefined;
	const conversion = items.find((i) => i.id === 'convert');

	return (
		<div className="flex flex-col gap-2">
			{items.length === 0 ? (
				<div className={SOLID}>
					<ModuleHeader title="Activity" />
					<span className="mt-1.5 text-[13px] font-semibold">Nothing running</span>
					<Note>
						Type <KeyCap>t 25m</KeyCap> in search to start a timer
					</Note>
				</div>
			) : (
				<button type="button" onClick={onOpenActivity} className={BUTTON} aria-label="Activity, show all">
					<ModuleHeader title="Activity" badge={badge} chevron />
					<span className="flex w-full flex-col">
						{items.slice(0, 3).map((item) => (
							<CompactActivityRow key={item.id} item={item} />
						))}
					</span>
				</button>
			)}

			<div className="grid auto-rows-[minmax(98px,auto)] grid-cols-2 gap-2">
				{timer.phase === 'running' || timer.phase === 'paused' ? (
					<button
						type="button"
						onClick={onToggleTimer}
						className={BUTTON}
						aria-label={timer.phase === 'running' ? 'Pause timer' : 'Resume timer'}
					>
						<ModuleHeader title={timer.label} />
						<span className="mt-2 flex w-full items-center justify-between gap-2">
							<span
								className={`text-[28px] leading-none font-semibold tracking-[-0.5px] tabular-nums ${
									timer.phase === 'paused' ? 'text-white/60' : 'text-white'
								}`}
							>
								{clock(remaining)}
							</span>
							<Ring value={timer.total ? 1 - remaining / timer.total : 0} size={24} />
						</span>
						<Note>{timer.phase === 'paused' ? 'Paused · click to resume' : 'Click to pause'}</Note>
					</button>
				) : (
					<div className={SOLID}>
						<ModuleHeader title="Timer" />
						<span className="mt-2 text-[13px] font-semibold">Start a timer</span>
						<span className="mt-2.5 flex flex-wrap gap-1.5">
							{(
								[
									['5 min', 5],
									['25 min', 25],
									['Pomodoro', 25],
								] as const
							).map(([label, minutes]) => (
								<button
									key={label}
									type="button"
									onClick={() => onStartTimer(label, minutes)}
									className="press h-[26px] rounded-full bg-white/10 px-2.5 text-[12px] font-medium text-white hover:bg-white/[0.16]"
								>
									{label}
								</button>
							))}
						</span>
					</div>
				)}

				<button type="button" onClick={() => onOpenSearch('clipboard')} className={BUTTON}>
					<ModuleHeader title="Clipboard" chevron />
					<span className="mt-2 line-clamp-2 font-mono text-[12px]">{CLIPS[0].title}</span>
					<Note>Notes · 1h</Note>
				</button>

				<button type="button" onClick={() => onOpenSearch('all')} className={BUTTON}>
					<ModuleHeader title="Search" />
					<span className="mt-2 flex items-center gap-1.5 text-[13px] font-semibold">
						<MagnifyingGlassIcon aria-hidden size={14} weight="bold" />
						Apps, files, math
					</span>
					<Note>
						Start typing, or <KeyCap>⌥Space</KeyCap>
					</Note>
				</button>

				<div className={`${CARD} border border-dashed border-white/20`}>
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
			</div>

			<div>
				<button
					type="button"
					onClick={onSettings}
					aria-label="Settings"
					className="press grid size-7 place-items-center rounded-full text-white/60 hover:bg-white/10 hover:text-white"
				>
					<GearSixIcon size={14} weight="bold" />
				</button>
			</div>
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
