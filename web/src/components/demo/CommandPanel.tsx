import {
	AppWindowIcon,
	ArrowElbowDownLeftIcon,
	CalendarBlankIcon,
	ChatCircleIcon,
	ClipboardTextIcon,
	CompassIcon,
	EnvelopeIcon,
	EqualsIcon,
	FigmaLogoIcon,
	GearSixIcon,
	GlobeIcon,
	HammerIcon,
	ImageIcon,
	LinkIcon,
	MonitorIcon,
	NoteIcon,
	PaletteIcon,
	TerminalWindowIcon,
	TextAlignLeftIcon,
	TimerIcon,
	TrashIcon,
	TrayIcon,
	type Icon,
} from '@phosphor-icons/react';
import { motion, useReducedMotion } from 'motion/react';
import { Fragment, useEffect, useRef, type KeyboardEvent, type ReactNode, type Ref } from 'react';
import { inlineAnswer } from './calc';
import { APPS, CLIPS, COMMANDS, type Clip, type Result, type Scope } from './data';

/** CommandPanelView.swift: 36 px rows, 28 px section headers, list capped at 360 px. */
const ROW_H = 36;
const HEADER_H = 28;
const MAX_LIST_H = 360;
/** ClipboardListView.swift: 40 px rows, 250 px list, split between 220 and 340 px tall. */
const CLIP_ROW_H = 40;

const APP_GLYPH: Record<string, Icon> = {
	figma: FigmaLogoIcon,
	ghostty: TerminalWindowIcon,
	xcode: HammerIcon,
	safari: CompassIcon,
	notes: NoteIcon,
	mail: EnvelopeIcon,
	calendar: CalendarBlankIcon,
	messages: ChatCircleIcon,
	wallpaper: ImageIcon,
	dock: AppWindowIcon,
	appearance: PaletteIcon,
	displays: MonitorIcon,
};

/** ResultIcon fallback: a tile in the kind's colour with a bold white symbol. */
const KIND_TILE: Record<Result['kind'], { icon: Icon; color: string }> = {
	app: { icon: AppWindowIcon, color: '#636366' },
	setting: { icon: GearSixIcon, color: '#636366' },
	command: { icon: ClipboardTextIcon, color: '#636366' },
	clip: { icon: TextAlignLeftIcon, color: '#636366' },
	answer: { icon: EqualsIcon, color: '#1f9e87' },
	timer: { icon: TimerIcon, color: '#ff9500' },
	web: { icon: GlobeIcon, color: '#0a8fd6' },
};

export function ResultTile({ result, size }: { result: Result; size: number }) {
	const Glyph = APP_GLYPH[result.id] ?? KIND_TILE[result.kind].icon;
	const color = result.tint ?? KIND_TILE[result.kind].color;
	const light = color === '#f2f2f2' || color === '#e8b923';
	return (
		<span
			aria-hidden
			className="grid shrink-0 place-items-center shadow-[inset_0_0_0_0.5px_rgb(255_255_255/0.18)]"
			style={{ width: size, height: size, borderRadius: size / 4, background: color }}
		>
			<Glyph size={size / 2 + 1} weight="bold" color={light ? '#1d1d1f' : '#fff'} />
		</span>
	);
}

export type Section = { title: string; rows: Result[] };

/** One sectioned list, in the order Perch's SearchEngine ranks them. */
export function buildSections(query: string): Section[] {
	const q = query.trim().toLowerCase();
	if (!q) {
		return [
			{ title: 'Recent', rows: APPS.filter((r) => r.id === 'ghostty' || r.id === 'figma') },
			{ title: 'Applications', rows: APPS.filter((r) => r.kind === 'app').sort((a, b) => a.title.localeCompare(b.title)) },
		];
	}
	const matches = (r: { title: string; keywords?: string }) => `${r.title} ${r.keywords ?? ''}`.toLowerCase().includes(q);

	const results: Result[] = [];
	const answer = inlineAnswer(q);
	if (answer) results.push({ id: 'answer', kind: 'answer', title: answer, meta: 'Answer' });
	const timer = /^(?:t\s*(\d{1,3})\s*m?|pomo(?:doro)?)$/.exec(q);
	if (timer) {
		const minutes = timer[1] ? Number(timer[1]) : 25;
		results.push({ id: 'timer', kind: 'timer', title: `Start a ${minutes} min timer`, meta: 'Timer', minutes });
	}
	const clips: Result[] = CLIPS.filter((c) => c.type !== 'Image' && matches(c))
		.slice(0, 3)
		.map((c) => ({ id: c.id, kind: 'clip', title: c.title, meta: 'Clipboard' }));
	const web: Result = { id: 'web', kind: 'web', title: `Search the web for “${query.trim()}”`, meta: 'Web' };

	const sections: Section[] = [
		{ title: 'Results', rows: results },
		{ title: 'Applications', rows: APPS.filter((r) => r.kind === 'app' && matches(r)) },
		{ title: 'System Settings', rows: APPS.filter((r) => r.kind === 'setting' && matches(r)) },
		{ title: 'Commands', rows: COMMANDS.filter(matches) },
		{ title: 'Clipboard', rows: clips },
		{ title: 'Search', rows: [web] },
	];
	return sections.filter((s) => s.rows.length > 0);
}

export function filterClips(query: string): Clip[] {
	const q = query.trim().toLowerCase();
	return q ? CLIPS.filter((c) => `${c.title} ${c.source}`.toLowerCase().includes(q)) : CLIPS;
}

export function actionTitle(r: Result) {
	switch (r.kind) {
		case 'app':
			return 'Open';
		case 'setting':
			return 'Open Pane';
		case 'command':
			return r.opensClipboard ? 'Show' : 'Open';
		case 'clip':
			return 'Paste';
		case 'answer':
			return 'Copy Answer';
		case 'timer':
			return 'Start';
		case 'web':
			return 'Search';
	}
}

/**
 * SearchFieldRow: 20 pt query, the scope as a pill on the left, and, once there is a query,
 * the selected result's action trailing the text in grey ("fig — Open") with its icon on the right.
 */
export function SearchRow({
	query,
	scope,
	selected,
	onQuery,
	onKeyDown,
	inputRef,
	activeId,
}: {
	query: string;
	scope: Scope;
	selected?: Result;
	onQuery: (q: string) => void;
	onKeyDown: (e: KeyboardEvent<HTMLInputElement>) => void;
	inputRef: Ref<HTMLInputElement>;
	activeId?: string;
}) {
	const hint = query.trim() && selected ? selected : undefined;
	return (
		<div className="flex h-16 items-center gap-3 pr-[18px] pl-6">
			{scope === 'clipboard' && (
				<span className="flex h-[26px] shrink-0 items-center rounded-full bg-white/[0.14] px-2.5 text-[13px] font-medium text-white/85">
					Clipboard History
				</span>
			)}
			<label htmlFor="perch-demo-q" className="sr-only">
				{scope === 'clipboard' ? 'Search clipboard history' : 'Search for apps, settings and commands'}
			</label>
			<span className="relative min-w-0 flex-1">
				<input
					id="perch-demo-q"
					ref={inputRef}
					value={query}
					onChange={(e) => onQuery(e.target.value)}
					onKeyDown={onKeyDown}
					role="combobox"
					aria-expanded="true"
					aria-controls="perch-demo-results"
					aria-activedescendant={activeId ? `perch-demo-${activeId}` : undefined}
					aria-autocomplete="list"
					autoComplete="off"
					spellCheck={false}
					placeholder={scope === 'clipboard' ? 'Search clipboard history…' : 'Search for apps, settings and commands…'}
					className="w-full bg-transparent text-[20px] text-white caret-white outline-none placeholder:text-white/40 focus-visible:outline-none"
				/>
				{hint && (
					<span aria-hidden className="pointer-events-none absolute inset-y-0 left-0 flex items-center overflow-hidden text-[20px] whitespace-pre">
						<span className="invisible">{query}</span>
						<span className="text-white/40"> — {actionTitle(hint)}</span>
					</span>
				)}
			</span>
			{hint && <ResultTile key={hint.id} result={hint} size={30} />}
		</div>
	);
}

/** Frosted panel shell shared by both lists: 520 wide, 12 px padding, 22 px corners, bright hairline. */
function PanelShell({ top, width, children }: { top: number; width: number; children: ReactNode }) {
	const reduce = useReducedMotion();
	return (
		<motion.div
			className="absolute left-1/2 z-30 rounded-[22px] border border-white/25 bg-[rgb(58_50_48/0.55)] p-3 text-white shadow-[0_20px_60px_rgb(0_0_0/0.3)] backdrop-blur-[30px] backdrop-saturate-[1.8] [@media(prefers-reduced-transparency:reduce)]:bg-[#2a2624] [@media(prefers-reduced-transparency:reduce)]:backdrop-blur-none"
			style={{ top, width, x: '-50%', originY: 0 }}
			initial={reduce ? { opacity: 0 } : { opacity: 0, y: -18, scale: 0.92 }}
			animate={{ opacity: 1, y: 0, scale: 1, transition: { type: 'spring', bounce: 0, duration: 0.5, delay: 0.06 } }}
			exit={reduce ? { opacity: 0 } : { opacity: 0, y: -12, scale: 0.96, transition: { duration: 0.18 } }}
		>
			{children}
		</motion.div>
	);
}

function KeyCap({ children }: { children: ReactNode }) {
	return (
		<kbd className="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-[5px] bg-white/[0.1] px-[5px] font-sans text-[11px] font-medium text-white/80">
			{children}
		</kbd>
	);
}

function Footer({ children }: { children: ReactNode }) {
	return (
		<div className="mt-2 flex items-center gap-2.5 border-t border-white/[0.12] px-2.5 pt-2.5 pb-0.5 text-[12px] whitespace-nowrap text-white/55">
			{children}
		</div>
	);
}

const Separator = () => <span className="h-3.5 w-px bg-white/15" />;

/** Keeps the selected row in view, like the app's ScrollViewReader. */
function useScrollToSelected(active: number) {
	const list = useRef<HTMLUListElement>(null);
	useEffect(() => {
		list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' });
	}, [active]);
	return list;
}

export function ResultsPanel({
	top,
	width,
	sections,
	active,
	query,
	escapeTitle,
	onHover,
	onRun,
}: {
	top: number;
	width: number;
	sections: Section[];
	active: number;
	query: string;
	escapeTitle: string;
	onHover: (index: number) => void;
	onRun: (result: Result) => void;
}) {
	const flat = sections.flatMap((s) => s.rows);
	const selected = flat[active];
	const height = Math.min(MAX_LIST_H, flat.length * ROW_H + sections.length * HEADER_H);
	const list = useScrollToSelected(active);
	let index = -1;

	return (
		<PanelShell top={top} width={width}>
			{flat.length === 0 ? (
				<p className="py-7 text-center text-[14px] text-white/55">No results for “{query.trim()}”</p>
			) : (
				<ul
					ref={list}
					id="perch-demo-results"
					role="listbox"
					aria-label="Results"
					className="overflow-y-auto [scrollbar-width:none]"
					style={{ height }}
				>
					{sections.map((section) => (
						<Fragment key={section.title}>
							<li
								role="presentation"
								className="flex items-end px-2.5 pb-1.5 text-[11px] font-semibold text-white/55"
								style={{ height: HEADER_H }}
							>
								{section.title}
							</li>
							{section.rows.map((r) => {
								index += 1;
								const i = index;
								const on = i === active;
								return (
									<li
										key={`${section.title}-${r.id}`}
										id={`perch-demo-${r.id}`}
										role="option"
										aria-selected={on}
										// Move, not enter: rows appearing under a resting cursor must not steal the selection.
										onPointerMove={() => i !== active && onHover(i)}
										onClick={() => onRun(r)}
										className={`flex cursor-default items-center gap-2.5 rounded-[10px] px-2.5 ${on ? 'bg-white/10' : ''}`}
										style={{ height: ROW_H }}
									>
										<ResultTile result={r} size={20} />
										<span className="min-w-0 flex-1 truncate text-[13px] font-medium text-white">{r.title}</span>
										<span className="shrink-0 text-[12px] text-white/55">{r.meta}</span>
									</li>
								);
							})}
						</Fragment>
					))}
				</ul>
			)}
			<Footer>
				<span className="flex min-w-0 items-center gap-1">
					<KeyCap>↑</KeyCap>
					<KeyCap>↓</KeyCap>
					<span className="truncate">Move</span>
				</span>
				<span className="flex-1" />
				{selected && (
					<>
						<span className="flex items-center gap-1.5 font-semibold text-white">
							{actionTitle(selected)}
							<KeyCap>
								<ArrowElbowDownLeftIcon size={11} weight="bold" />
							</KeyCap>
						</span>
						<Separator />
					</>
				)}
				<span className="flex items-center gap-1.5">
					{escapeTitle}
					<KeyCap>esc</KeyCap>
				</span>
			</Footer>
		</PanelShell>
	);
}

const CLIP_GLYPH: Record<Clip['type'], Icon> = { Text: TextAlignLeftIcon, Link: LinkIcon, Color: PaletteIcon, Image: ImageIcon };

function ClipTile({ clip }: { clip: Clip }) {
	if (clip.type === 'Image') {
		return (
			<span
				aria-hidden
				className="size-7 shrink-0 rounded-[6px] border border-white/20"
				style={{ background: clip.body }}
			/>
		);
	}
	const Glyph = CLIP_GLYPH[clip.type];
	return (
		<span aria-hidden className="grid size-7 shrink-0 place-items-center rounded-[6px] bg-white/10 text-white/60">
			{clip.type === 'Color' ? (
				<span className="size-3 rounded-[3px]" style={{ background: clip.body }} />
			) : (
				<Glyph size={13} weight="bold" />
			)}
		</span>
	);
}

function ClipPreview({ clip }: { clip: Clip }) {
	if (clip.type === 'Image') {
		return (
			<span className="flex h-full items-center justify-center">
				<span className="aspect-[1360/783] w-full rounded-[6px] border border-white/20" style={{ background: clip.body }} />
			</span>
		);
	}
	if (clip.type === 'Color') {
		return (
			<span className="flex h-full flex-col items-center justify-center gap-2">
				<span className="size-24 rounded-[10px] border border-white/20" style={{ background: clip.body }} />
				<span className="font-mono text-[13px]">{clip.body}</span>
			</span>
		);
	}
	return <p className="font-mono text-[12px] leading-snug break-words text-white">{clip.body}</p>;
}

/** ClipboardListView + ClipboardDetailView + ClipboardFooter: list on the left, preview and Information on the right. */
export function ClipboardPanel({
	top,
	width,
	clips,
	active,
	query,
	compact,
	onHover,
	onPaste,
	onCopy,
	onClear,
}: {
	top: number;
	width: number;
	clips: Clip[];
	active: number;
	query: string;
	compact: boolean;
	onHover: (index: number) => void;
	onPaste: (clip: Clip) => void;
	onCopy: (clip: Clip) => void;
	onClear: () => void;
}) {
	const clip = clips[active] ?? clips[0];
	const height = Math.min(340, Math.max(220, clips.length * CLIP_ROW_H));
	const list = useScrollToSelected(active);
	const info: [string, string][] = clip
		? [
				['Source', clip.source],
				['Type', clip.type === 'Image' ? 'Image' : 'Text'],
				...(clip.type === 'Image'
					? [['Dimensions', clip.title.replace('Image ', '')] as [string, string]]
					: ([
							['Characters', String(clip.body.length)],
							['Words', String(clip.body.split(/\s+/).filter(Boolean).length)],
						] as [string, string][])),
				['Copied', clip.copied],
			]
		: [];

	return (
		<PanelShell top={top} width={width}>
			{clips.length === 0 ? (
				<p className="py-7 text-center text-[14px] text-white/55">No clips match “{query.trim()}”</p>
			) : (
				<div className="flex" style={{ height }}>
					<ul
						ref={list}
						id="perch-demo-results"
						role="listbox"
						aria-label="Clipboard history"
						className={`shrink-0 overflow-y-auto [scrollbar-width:none] ${compact ? 'w-full' : 'w-[250px]'}`}
					>
						{clips.map((c, i) => (
							<li
								key={c.id}
								id={`perch-demo-${c.id}`}
								role="option"
								aria-selected={i === active}
								onPointerMove={() => i !== active && onHover(i)}
								onClick={() => onPaste(c)}
								className={`flex cursor-default items-center gap-2.5 rounded-[10px] px-2.5 ${i === active ? 'bg-white/10' : ''}`}
								style={{ height: CLIP_ROW_H }}
							>
								<ClipTile clip={c} />
								<span className="min-w-0 flex-1 truncate text-[13px] font-medium">{c.title}</span>
							</li>
						))}
					</ul>
					{!compact && clip && (
						<>
							<span className="mx-2.5 w-px bg-white/[0.12]" />
							<div className="flex min-w-0 flex-1 flex-col">
								<div className="min-h-0 flex-1 overflow-hidden">
									<ClipPreview clip={clip} />
								</div>
								<p className="pt-2.5 pb-0.5 text-[11px] font-semibold text-white/55">Information</p>
								<dl>
									{info.map(([label, value], i) => (
										<div
											key={label}
											className={`flex h-[26px] items-center justify-between gap-2 text-[12px] ${i > 0 ? 'border-t border-white/[0.12]' : ''}`}
										>
											<dt className="text-white/55">{label}</dt>
											<dd className="truncate">{value}</dd>
										</div>
									))}
								</dl>
							</div>
						</>
					)}
				</div>
			)}
			<Footer>
				<button
					type="button"
					onClick={onClear}
					className="press flex h-7 items-center gap-1.5 rounded-[8px] px-2 font-medium hover:bg-white/10"
				>
					<TrashIcon size={14} />
					Clear history
				</button>
				<span className="flex h-7 items-center gap-1.5 rounded-[8px] px-2 font-medium">
					<TrayIcon size={14} />
					All
				</span>
				<span className="flex-1" />
				{clip && !compact && (
					<>
						<button type="button" onClick={() => onCopy(clip)} className="flex items-center gap-1.5 hover:text-white">
							<KeyCap>⌘↵</KeyCap>
							Copy
						</button>
					</>
				)}
				{clip && (
					<button
						type="button"
						onClick={() => onPaste(clip)}
						className="press flex h-7 items-center gap-1.5 rounded-[8px] px-2 font-medium text-white hover:bg-white/10"
					>
						Paste
						<KeyCap>
							<ArrowElbowDownLeftIcon size={11} weight="bold" />
						</KeyCap>
					</button>
				)}
			</Footer>
		</PanelShell>
	);
}
