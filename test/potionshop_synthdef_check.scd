// potionshop_synthdef_check.scd
// Off-hardware build-check for the four-operator FM engine. CroneEngine is not
// available in vanilla sclang, so this mirrors the SynthDef graph and the
// algorithm -> params expansion from lib/Engine_Potionshop.sc and compiles them
// without a server. Run:
//
//     sclang test/potionshop_synthdef_check.scd   // -> "SYNTHDEFS_OK"
//
// Keep this in sync with lib/Engine_Potionshop.sc when the graph or the
// algorithm table changes. A non-zero exit / missing "SYNTHDEFS_OK" means the
// UGen graph or the algorithm expansion broke.

(
var algorithms, expand, defs;

// --- algorithm data table (mirror of Engine_Potionshop.algorithms) ---
algorithms = [
	[ [[4,3],[3,2],[2,1]],   [1] ],
	[ [[4,2],[3,2],[2,1]],   [1] ],
	[ [[4,3],[3,1],[2,1]],   [1] ],
	[ [[4,2],[3,1],[2,1]],   [1] ],
	[ [[2,1],[4,3]],         [1,3] ],
	[ [[4,1],[4,2],[4,3]],   [1,2,3] ],
	[ [[4,3]],               [1,2,3] ],
	[ [],                    [1,2,3,4] ]
];

// --- algorithm -> params expansion (mirror of the trig command handler) ---
expand = { arg algo, modIndex;
	var spec, edges, carriers, cgain, weights, pmIndex;
	spec = algorithms[algo - 1];
	edges = spec[0]; carriers = spec[1];
	cgain = carriers.size.max(1).sqrt.reciprocal;
	weights = IdentityDictionary.new;
	[\m21, \m31, \m41, \m32, \m42, \m43].do { |k| weights[k] = 0 };
	edges.do { |e| weights[("m" ++ e[0].asString ++ e[1].asString).asSymbol] = 1 };
	pmIndex = modIndex.linlin(1, 24, 0.5, 8);
	(weights.values.sum == edges.size).if({}, { Error("edge weight mismatch alg " ++ algo).throw });
	(cgain > 0).if({}, { Error("bad carrier gain alg " ++ algo).throw });
	[weights, cgain, pmIndex];
};

(1..8).do { |a| [1, 12, 24].do { |mi| expand.(a, mi) } };

// --- SynthDef graph (mirror of the PotionFM + PotionMaster defs) ---
defs = [
	SynthDef("PotionFM", { arg out = 0, freq = 220, amp = 0.3,
		brightnessStart = 2, brightnessEnd = 2, harmDecay = 0.001,
		m21 = 0, m31 = 0, m41 = 0, m32 = 0, m42 = 0, m43 = 0,
		c1 = 1, c2 = 0, c3 = 0, c4 = 0,
		lvl1 = 1, lvl2 = 1, lvl3 = 1, lvl4 = 1,
		modIndex = 4, feedback = 0,
		attack = 0.001, ampDecay = 0.4, ampCurve = -4,
		modDecay = 0.2, drive = 1, gate = 1;
		var ampEnv, cut, modEnv, mrEnv, r2, r3, r4, o1, o2, o3, o4, sig, driveMix;
		mrEnv = EnvGen.kr(Env.new(
			[brightnessStart.linlin(2, 25.25, 1, 7), brightnessEnd.linlin(2, 25.25, 1, 7)],
			[max(0.001, harmDecay)], \exp));
		r2 = mrEnv; r3 = (mrEnv * 2) - 1; r4 = (mrEnv * 3) - 2;
		modEnv = modIndex * EnvGen.kr(Env.perc(0.001, max(0.01, modDecay), 1.0, -4));
		ampEnv = EnvGen.kr(
			Env.perc(attack, max(0.01, ampDecay), 1.0, ampCurve),
			doneAction: Done.freeSelf
		);
		cut = EnvGen.kr(Env.asr(0, 1, 0.006, \lin), gate, doneAction: Done.freeSelf);
		o4 = SinOscFB.ar(freq * r4, feedback) * lvl4;
		o3 = SinOsc.ar(freq * r3, modEnv * (m43 * o4)) * lvl3;
		o2 = SinOsc.ar(freq * r2, modEnv * (m42 * o4 + m32 * o3)) * lvl2;
		o1 = SinOsc.ar(freq * 1,  modEnv * (m41 * o4 + m31 * o3 + m21 * o2)) * lvl1;
		sig = (c1 * o1) + (c2 * o2) + (c3 * o3) + (c4 * o4);
		sig = sig * ampEnv * cut * amp * 0.5;
		driveMix = (drive - 1).linlin(0, 7, 0, 1);
		sig = (sig * (1 - driveMix)) + ((sig * drive).tanh * driveMix);
		Out.ar(out, sig ! 2);
	}),
	SynthDef("PotionMaster", { arg in = 0, out = 0;
		var sig = In.ar(in, 2);
		sig = Limiter.ar(sig, 0.95, 0.01);
		Out.ar(out, sig);
	})
];

defs.do { |d| d.asBytes };   // force graph -> bytecode; throws on a malformed graph

"SYNTHDEFS_OK".postln;
0.exit;
)
