import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { useState, type ReactNode } from 'react';

/** One physical-looking key; it sinks while held, from the real keyboard or the pointer. */
function Key({ down, wide, children }: { down: boolean; wide?: boolean; children: ReactNode }) {
	return (
		<span
			aria-hidden
			className={`relative flex h-[68px] flex-col justify-between rounded-[14px] border border-white/[0.14] bg-[linear-gradient(180deg,#2c2c30,#1f1f22)] px-3.5 py-2.5 text-white transition-[transform,box-shadow] duration-100 ease-out sm:h-[76px] ${
				wide ? 'w-[188px] sm:w-[232px]' : 'w-[68px] sm:w-[76px]'
			} ${
				down
					? 'translate-y-[3px] shadow-[0_0_0_1px_rgb(255_159_10/0.7),0_1px_0_#0b0b0c,0_0_28px_rgb(255_159_10/0.35)]'
					: 'shadow-[inset_0_1px_0_rgb(255_255_255/0.08),0_4px_0_#0b0b0c,0_10px_24px_rgb(0_0_0/0.45)]'
			}`}
		>
			{children}
		</span>
	);
}

/**
 * The demo's centrepiece: ⌥ Space as two real keys. Pressing them on the keyboard sinks the caps and opens search;
 * clicking or tapping them does the same for visitors without a keyboard.
 */
export function HotkeyKeys({
	visible,
	altDown,
	spaceDown,
	className,
	onTrigger,
}: {
	visible: boolean;
	altDown: boolean;
	spaceDown: boolean;
	className: string;
	onTrigger: () => void;
}) {
	const reduce = useReducedMotion();
	const [pointerDown, setPointerDown] = useState(false);

	return (
		<AnimatePresence>
			{visible && (
				<motion.div
					key="hotkey"
					className={`absolute left-1/2 z-[8] flex flex-col items-center gap-3 ${className}`}
					style={{ x: '-50%' }}
					initial={reduce ? { opacity: 0 } : { opacity: 0, y: 12, scale: 0.96 }}
					animate={{ opacity: 1, y: 0, scale: 1, transition: { type: 'spring', bounce: 0, duration: 0.45, delay: 0.1 } }}
					exit={reduce ? { opacity: 0 } : { opacity: 0, y: 8, scale: 0.97, transition: { duration: 0.15 } }}
				>
					<button
						type="button"
						onPointerDown={() => setPointerDown(true)}
						onPointerUp={() => setPointerDown(false)}
						onPointerLeave={() => setPointerDown(false)}
						onClick={onTrigger}
						aria-label="Press Option Space to open Perch search"
						className="flex cursor-pointer items-end gap-2 rounded-[18px] p-1 focus-visible:outline-offset-4"
					>
						<Key down={altDown || pointerDown}>
							<span className="self-end font-sans text-[11px] text-white/55">option</span>
							<span className="text-[24px] leading-none">⌥</span>
						</Key>
						<Key down={spaceDown || pointerDown} wide>
							<span className="flex-1" />
							<span className="self-center text-[13px] font-medium text-white/80">space</span>
						</Key>
					</button>
					<p className="text-[13px] text-white/60">
						<span className="hidden sm:inline">Press it, or click the keys</span>
						<span className="sm:hidden">Tap the keys</span>
					</p>
				</motion.div>
			)}
		</AnimatePresence>
	);
}
