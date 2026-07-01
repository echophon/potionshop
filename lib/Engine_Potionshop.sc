// Engine_Potionshop.sc
// SuperCollider engine for the Norns port of potionshop.
//
// FOUR-OPERATOR FM voice (Yamaha DX21/DX27/DX100/TX81Z-style): 4 sine operators,
// 32 algorithms (operator routings: the classic 8 DX shapes + 8 extended PM
// routings (1..16) + 16 amplitude/ring-modulation & hybrid AM+FM routings (17..32)),
// and per-operator-style feedback. AM/ring depth reuses the modIndex macro for now.
// This replaced the earlier 2-op `PotionFM` voice (one carrier + one modulator);
// `Burst:fire` (lib/burst.lua) drives it per hit, adding a per-channel `algo`.
//
// --- Why top-down feed-forward instead of a LocalIn matrix ---
// Every standard DX 4-op algorithm is a DAG that can be numbered so modulation
// always flows high op -> low op (4->3->2->1). So the operators are evaluated in
// one top-down pass (op4 first), each output feeding the next operator's PHASE
// input -- sample-accurate within the block. SC's `LocalIn` feedback (one
// control-block / ~64-sample delay) would smear the inter-operator path, so it is
// avoided. The single feedback operator (op4, always a chain top in the standard
// set) uses `SinOscFB` for true 1-sample self-PM. This is phase modulation, the
// same thing the Yamaha chips do; the modulation index stays stable across pitch.
//
// Operator frequency ratios are PER-OPERATOR and per-channel: r1/r2/r3/r4 are all
// passed in from a curated, grid-editable set (lib/burst.lua RATIO_VALUES); op1
// defaults to 1.0 (the fundamental) but is now editable like the others, not
// pinned. This replaced the old single `harm` macro
// that fanned all three ratios out from unison via one scalar.
//
// Signal flow: PotionFM synths (in fmGroup, head) -> masterBus -> PotionMaster
// (Compander compressor -> makeup -> Limiter, at tail) -> engine output. The
// compressor evens out the loudness swing between algorithms (additive vs single
// carrier, PM vs over-modulated AM) so the limiter only catches rare peaks.
// Norns/Crone also soft-limits the main output; a 3-band compressor like the web
// master bus is the documented stretch beyond this single-band stage.

Engine_Potionshop : CroneEngine {
	var <fmGroup;
	var <masterBus;
	var <master;
	var <voices;        // one live voice node per channel (monophonic-per-channel)
	classvar numChannels = 6;

	// The 16 FM algorithms as DATA (1..8 are the canonical Yamaha 4-op DX set;
		// 9..16 are extended routings spread across carrier counts so each is
		// audibly distinct). Each entry lists the active modulation
	// edges (as [from-op, to-op], op numbers 1..4, always from > to) and the
	// carrier ops (which reach the output sum). Feedback lives on op4.
	//
	// NOTE: alg routings 2/3/4 vary slightly between published TX81Z charts;
	// these are the canonical chain / stacked / twin-stack / additive shapes.
	// Because algorithms are data, any correction is a one-line edit.
	classvar <algorithms;

	*initClass {
		// each entry = [ pmEdges, carriers, amEdges ]. pmEdges = phase-modulation
		// connections [from,to] (from > to). amEdges = amplitude/ring connections
		// [from,to,kind] where kind 0 = AM (carrier retained, tremolo/shimmer) and
		// 1 = ring (carrier suppressed, metallic). 1..16 are PM-only (empty amEdges);
		// 17..22 introduce AM/ring. With all ratios 5-limit, ring sidebands (C +/- M)
		// land on just thirds/fifths, so AM is the more 5-limit-coherent generator.
		algorithms = [
		//   pmEdges (from->to)               carriers     amEdges (from,to,kind)
			[ [[4,3],[3,2],[2,1]],            [1],         [] ],   // 1: 4->3->2->1 single stack
			[ [[4,2],[3,2],[2,1]],            [1],         [] ],   // 2: (4,3)->2->1 double-mod stack
			[ [[4,3],[3,1],[2,1]],            [1],         [] ],   // 3: 4->3->1, 2->1
			[ [[4,2],[3,1],[2,1]],            [1],         [] ],   // 4: 4->2->1, 3->1
			[ [[2,1],[4,3]],                  [1,3],       [] ],   // 5: twin 2-op stacks
			[ [[4,1],[4,2],[4,3]],            [1,2,3],     [] ],   // 6: op4 mods three carriers
			[ [[4,3]],                        [1,2,3],     [] ],   // 7: one stack + two bare carriers
			[ [],                             [1,2,3,4],   [] ],   // 8: additive (no modulation)
			[ [[4,1],[3,1],[2,1]],            [1],         [] ],   // 9: (4,3,2)->1 parallel triple-mod
			[ [[3,2],[2,1]],                  [1,4],       [] ],   // 10: 3->2->1 stack + pure op4
			[ [[4,2],[2,1]],                  [1,3],       [] ],   // 11: 4->2->1 stack + pure op3
			[ [[4,3],[3,2]],                  [1,2],       [] ],   // 12: 4->3->2 carrier + pure op1
			[ [[4,3],[3,1]],                  [1,2],       [] ],   // 13: 4->3->1 carrier + pure op2
			[ [[4,1],[3,1]],                  [1,2],       [] ],   // 14: (4,3)->1 + pure op2
			[ [[4,1],[4,2]],                  [1,2,3],     [] ],   // 15: op4 mods 2 carriers + pure op3
			[ [[4,2],[3,1]],                  [1,2],       [] ],   // 16: twin 2-op stacks (4->2, 3->1)
			[ [],                             [1,3,4],     [[2,1,1]] ],            // 17: op2 ring-mods op1; two bare carriers (metallic dyad)
			[ [],                             [1,3],       [[2,1,1],[4,3,1]] ],    // 18: twin ring pairs (ring analog of algo 5)
			[ [[4,3]],                        [1,2],       [[3,1,1]] ],           // 19: op4->op3 PM stack ring-mods op1; pure op2
			[ [],                             [1,2,3],     [[4,1,0],[4,2,0],[4,3,0]] ], // 20: op4 AM-shimmers three carriers (AM analog of algo 6)
			[ [],                             [1],         [[4,3,1],[3,2,1],[2,1,1]] ], // 21: ring chain 4(x)3(x)2(x)1 (bell)
			[ [[4,1],[3,1]],                  [1],         [[2,1,0]] ],           // 22: (4,3)->op1 PM + op2 AM-shimmers op1
			[ [],                             [1,3],       [[2,1,0],[4,3,0]] ],            // 23: twin AM pairs (2~1, 4~3) (AM analog of algo 5)
			[ [],                             [1,2,3],     [[4,1,1],[4,2,1],[4,3,1]] ],    // 24: op4 ring-mods three carriers (ring analog of algo 20)
			[ [[2,1]],                        [1,3],       [[4,3,0]] ],                    // 25: 2->1 PM stack + 4~3 AM pair (hybrid)
			[ [],                             [1],         [[4,3,0],[3,2,0],[2,1,0]] ],    // 26: AM chain 4~3~2~1 (AM analog of algo 21)
			[ [[4,1]],                        [1],         [[3,1,1],[2,1,0]] ],            // 27: op1 hit by PM(4) + ring(3) + AM(2)
			[ [[3,2],[2,1]],                  [1],         [[4,1,0]] ],                    // 28: 3->2->1 PM stack + op4 AM-shimmers op1
			[ [[4,2],[3,2]],                  [1],         [[2,1,1]] ],                    // 29: (4,3)->2 PM carrier ring-mods op1
			[ [],                             [1,2],       [[4,2,1],[3,1,1]] ],            // 30: twin ring pairs (4x2, 3x1) (ring analog of algo 16)
			[ [],                             [1,2],       [[4,2,0],[3,1,0]] ],            // 31: twin AM pairs (4~2, 3~1) (AM analog of algo 16)
			[ [[4,3]],                        [1],         [[3,2,0],[2,1,0]] ]             // 32: 4->3 PM then AM chain 3~2~1 (hybrid)
		];
	}

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		// --- four-operator FM voice ---
		// Operators evaluated top-down (op4 -> op1). `mAB` = whether op B
		// modulates op A (A < B); the global `modIndex` (radians) and the
		// modulator brightness env scale the depth. `cN` = carrier gain for opN.
		// r1/r2/r3/r4 are the per-operator frequency ratios (op1 default 1.0, editable), set
		// per-channel on the grid OP page (no longer a single harm macro).
		SynthDef("PotionFM", { arg out = 0, freq = 220, amp = 0.3,
			r1 = 1, r2 = 1, r3 = 1, r4 = 1,                 // per-operator ratios (op1 default 1.0)
			m21 = 0, m31 = 0, m41 = 0, m32 = 0, m42 = 0, m43 = 0,  // PM edges (from->to)
			a21 = 0, a31 = 0, a41 = 0, a32 = 0, a42 = 0, a43 = 0,  // AM edges (retain carrier)
			g21 = 0, g31 = 0, g41 = 0, g32 = 0, g42 = 0, g43 = 0,  // ring edges (suppress carrier)
			c1 = 1, c2 = 0, c3 = 0, c4 = 0,                 // carrier gains
			lvl1 = 1, lvl2 = 1, lvl3 = 1, lvl4 = 1,         // per-operator output levels
			modIndex = 4, amDepth = 0, feedback = 0,        // PM depth (rad), AM/ring depth (0..1), op4 self-FB (rad)
			atk1 = 0.001, dec1 = 0.4, atkCurve1 = -4, decCurve1 = -4,  // op1 EG (atk/dec times + per-segment curves)
			atk2 = 0.001, dec2 = 0.2, atkCurve2 = -4, decCurve2 = -4,  // op2 EG
			atk3 = 0.001, dec3 = 0.2, atkCurve3 = -4, decCurve3 = -4,  // op3 EG
			atk4 = 0.001, dec4 = 0.2, atkCurve4 = -4, decCurve4 = -4,  // op4 EG
			gate = 1,                                       // voice gate
			pan = 0;                                        // stereo position (-1 L .. +1 R)
			var e1, e2, e3, e4, cut, free, maxTime, o1, o2, o3, o4, sig;

			// PER-OPERATOR envelope generators (DX-style EG): each shapes its own
			// operator's output (unit 0->1->0). A carrier's eN is its amplitude
			// contour; a modulator's eN is the FM-depth / AM-depth / brightness
			// contour it imparts, because eN rides into oN, which feeds the lower
			// ops' phase (PM) and amplitude (AM/ring) terms below. Axes + per-segment
			// curves come from each per-channel sequenced opEnvN shape.
			e1 = EnvGen.kr(Env.new([0, 1, 0], [atk1, max(0.01, dec1)], [atkCurve1, decCurve1]));
			e2 = EnvGen.kr(Env.new([0, 1, 0], [atk2, max(0.01, dec2)], [atkCurve2, decCurve2]));
			e3 = EnvGen.kr(Env.new([0, 1, 0], [atk3, max(0.01, dec3)], [atkCurve3, decCurve3]));
			e4 = EnvGen.kr(Env.new([0, 1, 0], [atk4, max(0.01, dec4)], [atkCurve4, decCurve4]));

			// voice gate: each channel is monophonic, so a new hit releases the
			// previous voice on that channel over ~6ms (click-free) instead of
			// letting its tail drone into the next note. asr sits at 1 while gate=1
			// and frees on release.
			cut = EnvGen.kr(
				Env.asr(0, 1, 0.006, \lin), gate,
				doneAction: Done.freeSelf
			);

			// natural free: a silent timer that outlives the LONGEST operator
			// envelope, then frees the node. We can't put doneAction on the per-op
			// EGs individually -- the first to finish would cut a still-ringing
			// sibling -- so this single timer owns the lifetime. Does not shape sound.
			maxTime = max(max(atk1 + dec1, atk2 + dec2), max(atk3 + dec3, atk4 + dec4));
			free = EnvGen.kr(Env.new([0, 1], [maxTime + 0.05], \lin), doneAction: Done.freeSelf);

			// top-down pass: each operator's phase is modulated by the (already
			// computed) higher-numbered operators feeding it, scaled by the static
			// modIndex (PM depth, radians). op4 is the feedback operator (SinOscFB
			// self-PM); the rest take a phase input via SinOsc. Each operator's
			// output is scaled by its level `lvlN` AND its own envelope `eN`, so a
			// modulator's enveloped output IS its time-varying FM depth.
			o4 = SinOscFB.ar(freq * r4, feedback) * lvl4 * e4;
			o3 = SinOsc.ar(freq * r3, modIndex * (m43 * o4)) * lvl3 * e3;
			o2 = SinOsc.ar(freq * r2, modIndex * (m42 * o4 + m32 * o3)) * lvl2 * e2;
			o1 = SinOsc.ar(freq * r1, modIndex * (m41 * o4 + m31 * o3 + m21 * o2)) * lvl1 * e1;

			// amplitude/ring modulation post-pass (higher op modulates a lower op's
			// amplitude). Applied top-down (o3, o2, o1) so ring chains cascade through
			// the already-modified outputs. Depth = static amDepth (the modulating
			// op's own envelope already rides in oN), so amDepth = 0 leaves PM-only
			// algorithms untouched and dialing modIndex sweeps depth dry -> full. AM
			// keeps the carrier: o*(1 + amDepth*src). Ring crossfades carrier -> ringed:
			// o*(1 + amDepth*(src-1)) = o*src at full depth. Assumes at most one ring
			// source per target (true for the algorithm table).
			o3 = o3 * (1 + (amDepth * (a43 * o4)));
			o3 = o3 * (1 + (amDepth * (g43 * (o4 - 1))));
			o2 = o2 * (1 + (amDepth * (a42 * o4 + a32 * o3)));
			o2 = o2 * (1 + (amDepth * (g42 * (o4 - 1) + g32 * (o3 - 1))));
			o1 = o1 * (1 + (amDepth * (a41 * o4 + a31 * o3 + a21 * o2)));
			o1 = o1 * (1 + (amDepth * (g41 * (o4 - 1) + g31 * (o3 - 1) + g21 * (o2 - 1))));

			// sum carriers (each already enveloped by its own eN), apply voice-gate +
			// level. 0.5 master gain: halve the level range so a mid `level` reads as a
			// moderate hit rather than a heavy accent, and leave headroom for
			// additive / multi-channel sums (the limiter still backstops peaks).
			sig = (c1 * o1) + (c2 * o2) + (c3 * o3) + (c4 * o4);
			sig = sig * cut * amp * 0.5;

			// mono voice -> stereo field at the per-channel pan position.
			Out.ar(out, Pan2.ar(sig, pan));
		}).add;

		// --- master compressor + limiter ---
		// The six voices sum on masterBus with no per-voice loudness governing, so
		// additive algos (many carriers) and over-modulated AM patches can sit far
		// louder than a single-carrier stack. A Compander evens that out (gentle 3:1
		// above -10dBish) BEFORE the brickwall Limiter, so the limiter only catches
		// rare true peaks instead of hard-clamping every loud patch. makeup restores
		// the level the compression pulled down. A 3-band split is the documented
		// stretch beyond this single-band stage.
		SynthDef("PotionMaster", { arg in = 0, out = 0;
			var sig = In.ar(in, 2);
			sig = Compander.ar(sig, sig,
				thresh: 0.3,
				slopeBelow: 1,          // no expansion below thresh
				slopeAbove: 0.33,       // ~3:1 compression above thresh
				clampTime: 0.01,        // attack
				relaxTime: 0.1);        // release
			sig = sig * 1.5;            // makeup gain for the compressed level
			sig = Limiter.ar(sig, 0.95, 0.01);
			Out.ar(out, sig);
		}).add;

		context.server.sync;

		// voices write to a private bus; the limiter sums it to the output.
		fmGroup = Group.new(context.xg);            // head of the engine group
		voices = Array.newClear(numChannels);       // current voice per channel
		masterBus = Bus.audio(context.server, 2);
		master = Synth.tail(context.xg, "PotionMaster", [
			\in, masterBus.index, \out, context.out_b.index
		]);

		// trig(freq, amp, algo, r2, r3, r4, modIndex,
		//      feedback, ch, lvl1, lvl2, lvl3, lvl4, r1, pan,
		//      atk1, dec1, atkCurve1, decCurve1,   // op1 EG
		//      atk2, dec2, atkCurve2, decCurve2,   // op2 EG
		//      atk3, dec3, atkCurve3, decCurve3,   // op3 EG
		//      atk4, dec4, atkCurve4, decCurve4)   // op4 EG  -- 31 floats total
		//
		// `algo` (1..32) selects the routing/carrier data; the rest are the final
		// per-hit values Burst:fire already computes. The handler expands `algo`
		// into the SynthDef's edge weights + carrier gains (static per note). `ch`
		// (1..6) is the channel: each channel is monophonic, so a new hit releases
		// the previous voice on that channel before spawning the new one. lvl1..4
		// are the per-operator output levels; r1 is op1's per-channel ratio. Each
		// operator carries its OWN envelope (per-op EG) from its sequenced opEnvN
		// shape, resolved in Burst:fire to {atk, dec, atkCurve, decCurve} and grouped
		// per op at args 16..31.
		this.addCommand("trig", "fffffffffffffffffffffffffffffff", { arg msg;
			var freq = msg[1], amp = msg[2];
			var algo = msg[3].asInteger.clip(1, 32);
			var r2 = msg[4], r3 = msg[5], r4 = msg[6];
			var modIndex = msg[7];
			var feedback = msg[8];
			var ch = msg[9].asInteger.clip(1, numChannels);
			var lvl1 = msg[10], lvl2 = msg[11], lvl3 = msg[12], lvl4 = msg[13];
			var r1 = msg[14];
			var pan = msg[15];
			var atk1 = msg[16], dec1 = msg[17], atkCurve1 = msg[18], decCurve1 = msg[19];
			var atk2 = msg[20], dec2 = msg[21], atkCurve2 = msg[22], decCurve2 = msg[23];
			var atk3 = msg[24], dec3 = msg[25], atkCurve3 = msg[26], decCurve3 = msg[27];
			var atk4 = msg[28], dec4 = msg[29], atkCurve4 = msg[30], decCurve4 = msg[31];
			var spec, edges, carriers, amEdges, cgain, weights, amWeights, pmIndex, amDepth, voice;

			spec = algorithms[algo - 1];
			edges = spec[0];
			carriers = spec[1];
			amEdges = spec[2];
			// normalize so additive (4-carrier) algorithms aren't 4x louder than
			// single-carrier stacks; equal-power-ish 1/sqrt(n).
			cgain = carriers.size.max(1).sqrt.reciprocal;

			// PM edge weights: 1 where the algorithm has a connection, else 0.
			weights = IdentityDictionary.new;
			[\m21, \m31, \m41, \m32, \m42, \m43].do { |k| weights[k] = 0 };
			edges.do { |e|
				weights[("m" ++ e[0].asString ++ e[1].asString).asSymbol] = 1;  // [from,to] -> m<from><to>
			};

			// AM/ring edge weights: aNN = AM (retain carrier), gNN = ring (suppress).
			// amEdge = [from, to, kind]; kind 1 -> ring (g), else AM (a).
			amWeights = IdentityDictionary.new;
			[\a21, \a31, \a41, \a32, \a42, \a43,
			 \g21, \g31, \g41, \g32, \g42, \g43].do { |k| amWeights[k] = 0 };
			amEdges.do { |e|
				var prefix = (e[2] == 1).if("g", "a");  // ring vs AM
				amWeights[(prefix ++ e[0].asString ++ e[1].asString).asSymbol] = 1;
			};

			// modIndex (sequencer 1..32) -> PM depth in radians, reused as the AM/ring
			// depth so one macro drives both generators for now. AM spans the full 1..32
			// grid and tops out at 2.0 (over-modulation): past 1.0 the (1 + amDepth*src)
			// term inverts and folds, so the high steps push AM/ring toward metallic,
			// sideband-rich territory rather than plain 100% tremolo.
			pmIndex = modIndex.linlin(1, 32, 0.5, 8);
			amDepth = modIndex.linlin(1, 32, 0, 2);

			// release any voice still ringing on this channel so it can't drone
			// into the new note (gate=0 -> ~6ms fade + free). `set` on an already
			// freed node is harmless; onFree below clears the slot once gone.
			voices[ch - 1] !? { |v| v.set(\gate, 0) };

			voice = Synth("PotionFM", [
				\out, masterBus.index, \freq, freq, \amp, amp,
				\r1, r1, \r2, r2, \r3, r3, \r4, r4,
				\m21, weights[\m21], \m31, weights[\m31], \m41, weights[\m41],
				\m32, weights[\m32], \m42, weights[\m42], \m43, weights[\m43],
				\a21, amWeights[\a21], \a31, amWeights[\a31], \a41, amWeights[\a41],
				\a32, amWeights[\a32], \a42, amWeights[\a42], \a43, amWeights[\a43],
				\g21, amWeights[\g21], \g31, amWeights[\g31], \g41, amWeights[\g41],
				\g32, amWeights[\g32], \g42, amWeights[\g42], \g43, amWeights[\g43],
				\amDepth, amDepth,
				\c1, carriers.includes(1).if(cgain, 0),
				\c2, carriers.includes(2).if(cgain, 0),
				\c3, carriers.includes(3).if(cgain, 0),
				\c4, carriers.includes(4).if(cgain, 0),
				\lvl1, lvl1, \lvl2, lvl2, \lvl3, lvl3, \lvl4, lvl4,
				\modIndex, pmIndex, \feedback, feedback,
				\atk1, atk1, \dec1, dec1, \atkCurve1, atkCurve1, \decCurve1, decCurve1,
				\atk2, atk2, \dec2, dec2, \atkCurve2, atkCurve2, \decCurve2, decCurve2,
				\atk3, atk3, \dec3, dec3, \atkCurve3, atkCurve3, \decCurve3, decCurve3,
				\atk4, atk4, \dec4, dec4, \atkCurve4, atkCurve4, \decCurve4, decCurve4,
				\pan, pan
			], fmGroup);
			voices[ch - 1] = voice;
			// clear the slot when the voice frees itself (perc done or gate release)
			// so we never address a dead node.
			voice.onFree { if(voices[ch - 1] == voice) { voices[ch - 1] = nil } };
		});

		// stop all currently-ringing voices (e.g. on script stop).
		this.addCommand("panic", "", { arg msg;
			fmGroup.freeAll;
			voices.fill(nil);
		});
	}

	free {
		master.free;
		fmGroup.free;
		masterBus.free;
	}
}
