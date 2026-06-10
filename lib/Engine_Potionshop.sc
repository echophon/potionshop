// Engine_Potionshop.sc
// SuperCollider engine for the Norns port of potionshop.
//
// FM voice ported from the web app's src/voice.ts (FMVoice): a sine carrier
// linear-FM'd by a sine modulator at freq*harm, with a percussive amplitude
// envelope and an exponentially-decaying modulation depth. The browser app
// kept an 8-slot voice pool; here each `trig` spawns a fresh Synth that frees
// itself (doneAction: 2), so SC's node scheduler is the voice allocator.
//
// `voiceType` is accepted by trig but ignored this pass — the JF (additive) and
// Mangrove (formant) voices route to the FM SynthDef for now. Add SynthDefs
// "PotionJF"/"PotionMG" and branch in trig to extend (see README).
//
// Signal flow: PotionFM synths (in fmGroup, head) -> masterBus -> PotionMaster
// (Limiter, at tail) -> engine output. Norns/Crone also soft-limits the main
// output; a 3-band compressor like the web master bus is a documented stretch.

Engine_Potionshop : CroneEngine {
	var <fmGroup;
	var <masterBus;
	var <master;
	var modIndexDefault = 8;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		// --- FM voice (mirrors FMVoice.triggerAt) ---
		SynthDef("PotionFM", { arg out = 0, freq = 220, amp = 0.5, harm = 2,
			modIndex = 8, attack = 0.001, ampDecay = 0.4, modDecay = 0.05;
			var modEnv, modDepth, mod, ampEnv, car, sig;

			// modulator depth: rise to peak in 1ms, then exponential decay.
			// peak depth (Hz) = freq * modIndex * amp, matching the web app.
			modEnv = EnvGen.kr(Env.new(
				levels: [0.0001, 1.0, 0.0001],
				times:  [0.001, max(0.001, modDecay)],
				curve:  [\lin, \exp]
			));
			modDepth = freq * modIndex * amp * modEnv;
			mod = SinOsc.ar(freq * harm, 0, modDepth);

			// percussive amp envelope; doneAction frees the synth on completion.
			ampEnv = EnvGen.kr(
				Env.perc(attack, max(0.01, ampDecay), 1.0, -4.0),
				doneAction: Done.freeSelf
			);

			// linear FM: carrier frequency offset by the modulator (in Hz).
			car = SinOsc.ar(freq + mod);
			sig = car * ampEnv * amp;
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
		masterBus = Bus.audio(context.server, 2);
		master = Synth.tail(context.xg, "PotionMaster", [
			\in, masterBus.index, \out, context.out_b.index
		]);

		// trig(freq, amp, harm, modIndex, attack, ampDecay, modDecay)
		this.addCommand("trig", "fffffff", { arg msg;
			Synth("PotionFM", [
				\out, masterBus.index,
				\freq, msg[1], \amp, msg[2], \harm, msg[3],
				\modIndex, msg[4], \attack, msg[5], \ampDecay, msg[6], \modDecay, msg[7]
			], fmGroup);
		});

		// stop all currently-ringing voices (e.g. on script stop).
		this.addCommand("panic", "", { arg msg;
			fmGroup.freeAll;
		});
	}

	free {
		master.free;
		fmGroup.free;
		masterBus.free;
	}
}
