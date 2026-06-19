// Engine_Potionshop.sc
// SuperCollider engine for the Norns port of potionshop.
//
// FOUR-OPERATOR FM voice (Yamaha DX21/DX27/DX100/TX81Z-style): 4 sine operators,
// the classic 8 algorithms (operator routings), and per-operator-style feedback.
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
// The bright->clean harm sweep from the old voice is preserved: the modulator
// RATIO SPREAD glides harmStart -> harmEnd over harmDecay (an Env inside the
// SynthDef), so the channel's harm-envelope modes still bend the timbre.
//
// Signal flow: PotionFM synths (in fmGroup, head) -> masterBus -> PotionMaster
// (Limiter, at tail) -> engine output. Norns/Crone also soft-limits the main
// output; a 3-band compressor like the web master bus is a documented stretch.

Engine_Potionshop : CroneEngine {
	var <fmGroup;
	var <masterBus;
	var <master;
	var <voices;        // one live voice node per channel (monophonic-per-channel)
	classvar numChannels = 6;

	// The 8 DX-style algorithms as DATA. Each entry lists the active modulation
	// edges (as [from-op, to-op], op numbers 1..4, always from > to) and the
	// carrier ops (which reach the output sum). Feedback lives on op4.
	//
	// NOTE: alg routings 2/3/4 vary slightly between published TX81Z charts;
	// these are the canonical chain / stacked / twin-stack / additive shapes.
	// Because algorithms are data, any correction is a one-line edit.
	classvar <algorithms;

	*initClass {
		algorithms = [
		//   edges (from->to)                carriers
			[ [[4,3],[3,2],[2,1]],            [1] ],          // 1: 4->3->2->1 single stack
			[ [[4,2],[3,2],[2,1]],            [1] ],          // 2: (4,3)->2->1 double-mod stack
			[ [[4,3],[3,1],[2,1]],            [1] ],          // 3: 4->3->1, 2->1
			[ [[4,2],[3,1],[2,1]],            [1] ],          // 4: 4->2->1, 3->1
			[ [[2,1],[4,3]],                  [1,3] ],        // 5: twin 2-op stacks
			[ [[4,1],[4,2],[4,3]],            [1,2,3] ],      // 6: op4 mods three carriers
			[ [[4,3]],                        [1,2,3] ],      // 7: one stack + two bare carriers
			[ [],                             [1,2,3,4] ]     // 8: additive (no modulation)
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
		// Modulator ratio spread sweeps brightnessStart -> brightnessEnd.
		SynthDef("PotionFM", { arg out = 0, freq = 220, amp = 0.3,
			brightnessStart = 2, brightnessEnd = 2, harmDecay = 0.001,
			m21 = 0, m31 = 0, m41 = 0, m32 = 0, m42 = 0, m43 = 0,  // mod edges (from->to)
			c1 = 1, c2 = 0, c3 = 0, c4 = 0,                 // carrier gains
			lvl1 = 1, lvl2 = 1, lvl3 = 1, lvl4 = 1,         // per-operator output levels
			modIndex = 4, feedback = 0,                     // global PM depth (rad), op4 self-FB (rad)
			attack = 0.001, ampDecay = 0.4, ampCurve = -4,  // carrier amp env (perc)
			modDecay = 0.2, drive = 1, gate = 1;            // modulator brightness env, soft-clip, voice gate
			var ampEnv, cut, modEnv, mrEnv, r2, r3, r4, o1, o2, o3, o4, sig, driveMix;

			// modulator ratio spread: brightness (~2..25) -> a spread amount mr
			// (1..7), swept start -> end over harmDecay so the FM sidebands glide
			// bright -> clean (or stay static when start == end / harm env off).
			// The spread opens FROM UNISON: at mr=1 every modulator sits on the
			// fundamental (cleanest, near a 2-op), and rises to a wide odd-harmonic
			// stack as harm climbs. This makes lowest-harm a genuinely clean tone.
			mrEnv = EnvGen.kr(Env.new(
				[brightnessStart.linlin(2, 25.25, 1, 7), brightnessEnd.linlin(2, 25.25, 1, 7)],
				[max(0.001, harmDecay)], \exp));
			r2 = mrEnv; r3 = (mrEnv * 2) - 1; r4 = (mrEnv * 3) - 2;  // op1 = fundamental (r1 = 1)

			// modulator brightness envelope: scales every modulation depth so the
			// timbre brightens at the attack and decays over the note.
			modEnv = modIndex * EnvGen.kr(Env.perc(0.001, max(0.01, modDecay), 1.0, -4));

			// percussive carrier amp env; frees the synth on completion.
			ampEnv = EnvGen.kr(
				Env.perc(attack, max(0.01, ampDecay), 1.0, ampCurve),
				doneAction: Done.freeSelf
			);

			// voice gate: each channel is monophonic, so a new hit releases the
			// previous voice on that channel over ~6ms (click-free) instead of
			// letting its tail drone into the next note. asr sits at 1 while gate=1
			// and frees on release; the perc env above frees first if it completes.
			cut = EnvGen.kr(
				Env.asr(0, 1, 0.006, \lin), gate,
				doneAction: Done.freeSelf
			);

			// top-down pass: each operator's phase is modulated by the (already
			// computed) higher-numbered operators feeding it. op4 is the feedback
			// operator (SinOscFB self-PM); the rest take a phase input via SinOsc.
			// Each operator's output is scaled by its level `lvlN` -- which doubles
			// as its FM depth when it modulates a lower op (it carries lvl into the
			// phase term below) and its mix gain when it's a carrier (in the sum).
			o4 = SinOscFB.ar(freq * r4, feedback) * lvl4;
			o3 = SinOsc.ar(freq * r3, modEnv * (m43 * o4)) * lvl3;
			o2 = SinOsc.ar(freq * r2, modEnv * (m42 * o4 + m32 * o3)) * lvl2;
			o1 = SinOsc.ar(freq * 1,  modEnv * (m41 * o4 + m31 * o3 + m21 * o2)) * lvl1;

			// sum carriers, apply amp env + voice-gate + level.
			// 0.5 master gain: halve the level range so a mid `level` reads as a
			// moderate hit rather than a heavy accent, and leave headroom for
			// additive / multi-channel sums (the limiter still backstops peaks).
			sig = (c1 * o1) + (c2 * o2) + (c3 * o3) + (c4 * o4);
			sig = sig * ampEnv * cut * amp * 0.5;

			// soft-clip drive: drive=1 is clean, higher blends in tanh saturation
			// and raises pre-gain together. Master Limiter catches the peaks.
			driveMix = (drive - 1).linlin(0, 7, 0, 1);
			sig = (sig * (1 - driveMix)) + ((sig * drive).tanh * driveMix);
			Out.ar(out, sig ! 2);
		}).add;

		// --- master limiter ---
		SynthDef("PotionMaster", { arg in = 0, out = 0;
			var sig = In.ar(in, 2);
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

		// trig(freq, amp, algo, harmStart, harmEnd, harmDecay, modIndex,
		//      attack, ampDecay, ampCurve, modDecay, feedback, drive, ch,
		//      lvl1, lvl2, lvl3, lvl4)
		//
		// `algo` (1..8) selects the routing/carrier data; the rest are the final
		// per-hit values Burst:fire already computes. The handler expands `algo`
		// into the SynthDef's edge weights + carrier gains (static per note). `ch`
		// (1..6) is the channel: each channel is monophonic, so a new hit releases
		// the previous voice on that channel before spawning the new one. lvl1..4
		// are the global per-operator output levels.
		this.addCommand("trig", "ffffffffffffffffff", { arg msg;
			var freq = msg[1], amp = msg[2];
			var algo = msg[3].asInteger.clip(1, 8);
			var harmStart = msg[4], harmEnd = msg[5], harmDecay = msg[6];
			var modIndex = msg[7];
			var attack = msg[8], ampDecay = msg[9], ampCurve = msg[10], modDecay = msg[11];
			var feedback = msg[12], drive = msg[13];
			var ch = msg[14].asInteger.clip(1, numChannels);
			var lvl1 = msg[15], lvl2 = msg[16], lvl3 = msg[17], lvl4 = msg[18];
			var spec, edges, carriers, cgain, weights, pmIndex, voice;

			spec = algorithms[algo - 1];
			edges = spec[0];
			carriers = spec[1];
			// normalize so additive (4-carrier) algorithms aren't 4x louder than
			// single-carrier stacks; equal-power-ish 1/sqrt(n).
			cgain = carriers.size.max(1).sqrt.reciprocal;

			// edge weights: 1 where the algorithm has a connection, else 0.
			weights = IdentityDictionary.new;
			[\m21, \m31, \m41, \m32, \m42, \m43].do { |k| weights[k] = 0 };
			edges.do { |e|
				weights[("m" ++ e[0].asString ++ e[1].asString).asSymbol] = 1;  // [from,to] -> m<from><to>
			};

			// modIndex (sequencer 1..24) -> PM depth in radians.
			pmIndex = modIndex.linlin(1, 24, 0.5, 8);

			// release any voice still ringing on this channel so it can't drone
			// into the new note (gate=0 -> ~6ms fade + free). `set` on an already
			// freed node is harmless; onFree below clears the slot once gone.
			voices[ch - 1] !? { |v| v.set(\gate, 0) };

			voice = Synth("PotionFM", [
				\out, masterBus.index, \freq, freq, \amp, amp,
				\brightnessStart, harmStart, \brightnessEnd, harmEnd, \harmDecay, harmDecay,
				\m21, weights[\m21], \m31, weights[\m31], \m41, weights[\m41],
				\m32, weights[\m32], \m42, weights[\m42], \m43, weights[\m43],
				\c1, carriers.includes(1).if(cgain, 0),
				\c2, carriers.includes(2).if(cgain, 0),
				\c3, carriers.includes(3).if(cgain, 0),
				\c4, carriers.includes(4).if(cgain, 0),
				\lvl1, lvl1, \lvl2, lvl2, \lvl3, lvl3, \lvl4, lvl4,
				\modIndex, pmIndex, \feedback, feedback,
				\attack, attack, \ampDecay, ampDecay, \ampCurve, ampCurve,
				\modDecay, modDecay, \drive, drive
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
