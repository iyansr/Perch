/** Inline answers for the demo search field: arithmetic (`24*7`) and unit conversion (`5 km to mi`). */

const UNITS: Record<string, { dim: string; factor: number; offset?: number }> = {
	mm: { dim: 'length', factor: 0.001 },
	cm: { dim: 'length', factor: 0.01 },
	m: { dim: 'length', factor: 1 },
	km: { dim: 'length', factor: 1000 },
	in: { dim: 'length', factor: 0.0254 },
	ft: { dim: 'length', factor: 0.3048 },
	yd: { dim: 'length', factor: 0.9144 },
	mi: { dim: 'length', factor: 1609.344 },
	g: { dim: 'mass', factor: 0.001 },
	kg: { dim: 'mass', factor: 1 },
	oz: { dim: 'mass', factor: 0.028349523125 },
	lb: { dim: 'mass', factor: 0.45359237 },
	c: { dim: 'temp', factor: 1, offset: 0 },
	f: { dim: 'temp', factor: 5 / 9, offset: -32 },
	k: { dim: 'temp', factor: 1, offset: -273.15 },
};

function format(n: number) {
	if (!Number.isFinite(n)) return null;
	const rounded = Math.round(n * 1e6) / 1e6;
	return rounded.toLocaleString('en-US', { maximumFractionDigits: 6 });
}

function convert(query: string) {
	const match = /^(-?\d+(?:\.\d+)?)\s*°?([a-z]+)\s+(?:to|in)\s+°?([a-z]+)$/i.exec(query.trim());
	if (!match) return null;
	const from = UNITS[match[2].toLowerCase()];
	const to = UNITS[match[3].toLowerCase()];
	if (!from || !to || from.dim !== to.dim) return null;
	// Through the base unit; temperature scales carry an offset before the factor.
	const value = Number(match[1]);
	const base = from.offset === undefined ? value * from.factor : (value + from.offset) * from.factor;
	const out = format(to.offset === undefined ? base / to.factor : base / to.factor - to.offset);
	return out === null ? null : `${out} ${match[3].toLowerCase()}`;
}

/** Recursive-descent arithmetic: + - * / % ^ and parentheses. Returns null for anything else. */
function evaluate(query: string) {
	const src = query.replace(/\s+/g, '').replace(/×/g, '*').replace(/÷/g, '/');
	if (!/^[\d.+\-*/%^()]+$/.test(src) || !/[+\-*/%^]/.test(src.replace(/^-/, ''))) return null;
	let i = 0;

	const peek = () => src[i];
	const number = (): number => {
		const start = i;
		while (i < src.length && /[\d.]/.test(src[i])) i++;
		const n = Number(src.slice(start, i));
		if (start === i || Number.isNaN(n)) throw new Error('number');
		return n;
	};
	const atom = (): number => {
		if (peek() === '-') {
			i++;
			return -atom();
		}
		if (peek() === '(') {
			i++;
			const v = sum();
			if (src[i++] !== ')') throw new Error('paren');
			return v;
		}
		return number();
	};
	const power = (): number => {
		const base = atom();
		if (peek() === '^') {
			i++;
			return base ** power();
		}
		return base;
	};
	const product = (): number => {
		let v = power();
		while (peek() === '*' || peek() === '/' || peek() === '%') {
			const op = src[i++];
			const r = power();
			v = op === '*' ? v * r : op === '/' ? v / r : v % r;
		}
		return v;
	};
	const sum = (): number => {
		let v = product();
		while (peek() === '+' || peek() === '-') {
			const op = src[i++];
			const r = product();
			v = op === '+' ? v + r : v - r;
		}
		return v;
	};

	try {
		const v = sum();
		return i === src.length ? format(v) : null;
	} catch {
		return null;
	}
}

export function inlineAnswer(query: string): string | null {
	return convert(query) ?? evaluate(query);
}
