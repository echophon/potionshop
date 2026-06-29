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
// each entry = [ pmEdges, carriers, amEdges ]; amEdge = [from, to, kind] (1 = ring).
algorithms = [
	[ [[4,3],[3,2],[2,1]],   [1],       [] ],
	[ [[4,2],[3,2],[2,1]],   [1],       [] ],
	[ [[4,3],[3,1],[2,1]],   [1],       [] ],
	[ [[4,2],[3,1],[2,1]],   [1],       [] ],
	[ [[2,1],[4,3]],         [1,3],     [] ],
	[ [[4,1],[4,2],[4,3]],   [1,2,3],   [] ],
	[ [[4,3]],               [1,2,3],   [] ],
	[ [],                    [1,2,3,4], [] ],
	[ [[4,1],[3,1],[2,1]],   [1],       [] ],
	[ [[3,2],[2,1]],         [1,4],     [] ],
	[ [[4,2],[2,1]],         [1,3],     [] ],
	[ [[4,3],[3,2]],         [1,2],     [] ],
	[ [[4,3],[3,1]],         [1,2],     [] ],
	[ [[4,1],[3,1]],         [1,2],     [] ],
	[ [[4,1],[4,2]],         [1,2,3],   [] ],
	[ [[4,2],[3,1]],         [1,2],     [] ],
	[ [],                    [1,3,4],   [[2,1,1]] ],
	[ [],                    [1,3],     [[2,1,1],[4,3,1]] ],
	[ [[4,3]],               [1,2],     [[3,1,1]] ],
	[ [],                    [1,2,3],   [[4,1,0],[4,2,0],[4,3,0]] ],
	[ [],                    [1],       [[4,3,1],[3,2,1],[2,1,1]] ],
	[ [[4,1],[3,1]],         [1],       [[2,1,0]] ],
	[ [],                    [1,3],     [[2,1,0],[4,3,0]] ],            // 23
	[ [],                    [1,2,3],   [[4,1,1],[4,2,1],[4,3,1]] ],    // 24
	[ [[2,1]],               [1,3],     [[4,3,0]] ],                    // 25
	[ [],                    [1],       [[4,3,0],[3,2,0],[2,1,0]] ],    // 26
	[ [[4,1]],               [1],       [[3,1,1],[2,1,0]] ],            // 27
	[ [[3,2],[2,1]],         [1],       [[4,1,0]] ],                    // 28
	[ [[4,2],[3,2]],         [1],       [[2,1,1]] ],                    // 29
	[ [],                    [1,2],     [[4,2,1],[3,1,1]] ],            // 30
	[ [],                    [1,2],     [[4,2,0],[3,1,0]] ],            // 31
	[ [[4,3]],               [1],       [[3,2,0],[2,1,0]] ]             // 32
];

// --- algorithm -> params expansion (mirror of the trig command handler) ---
expand = { arg algo, modIndex;
	var spec, edges, carriers, amEdges, cgain, weights, amWeights, pmIndex, amDepth;
	spec = algorithms[algo - 1];
	edges = spec[0]; carriers = spec[1]; amEdges = spec[2];
	cgain = carriers.size.max(1).sqrt.reciprocal;
	weights = IdentityDictionary.new;
	[\m21, \m31, \m41, \m32, \m42, \m43].do { |k| weights[k] = 0 };
	edges.do { |e| weights[("m" ++ e[0].asString ++ e[1].asString).asSymbol] = 1 };
	amWeights = IdentityDictionary.new;
	[\a21,\a31,\a41,\a32,\a42,\a43,\g21,\g31,\g41,\g32,\g42,\g43].do { |k| amWeights[k] = 0 };
	amEdges.do { |e|
		var prefix = (e[2] == 1).if("g", "a");
		amWeights[(prefix ++ e[0].asString ++ e[1].asString).asSymbol] = 1;
	};
	pmIndex = modIndex.linlin(1, 24, 0.5, 8);
	amDepth = modIndex.linlin(1, 24, 0, 1);
	(weights.values.sum == edges.size).if({}, { Error("edge weight mismatch alg " ++ algo).throw });
	(amWeights.values.sum == amEdges.size).if({}, { Error("am weight mismatch alg " ++ algo).throw });
	(cgain > 0).if({}, { Error("bad carrier gain alg " ++ algo).throw });
	[weights, amWeights, cgain, pmIndex, amDepth];
};

(1..32).do { |a| [1, 12, 24].do { |mi| expand.(a, mi) } };

// --- SynthDef graph (mirror of the PotionFM + PotionMaster defs) ---
defs = [
	SynthDef("PotionFM", { arg out = 0, freq = 220, amp = 0.3,
		r1 = 1, r2 = 1, r3 = 1, r4 = 1,
		m21 = 0, m31 = 0, m41 = 0, m32 = 0, m42 = 0, m43 = 0,
		a21 = 0, a31 = 0, a41 = 0, a32 = 0, a42 = 0, a43 = 0,
		g21 = 0, g31 = 0, g41 = 0, g32 = 0, g42 = 0, g43 = 0,
		c1 = 1, c2 = 0, c3 = 0, c4 = 0,
		lvl1 = 1, lvl2 = 1, lvl3 = 1, lvl4 = 1,
		modIndex = 4, amDepth = 0, feedback = 0,
		attack = 0.001, ampDecay = 0.4, ampAtkCurve = -4, ampDecCurve = -4,
		modAttack = 0.001, modDecay = 0.2, modAtkCurve = -4, modDecCurve = -4,
		drive = 1, gate = 1;
		var ampEnv, cut, mEnv, modEnv, amEnv, o1, o2, o3, o4, sig, driveMix;
		mEnv = EnvGen.kr(
			Env.new([0, 1, 0], [modAttack, max(0.01, modDecay)], [modAtkCurve, modDecCurve])
		);
		modEnv = modIndex * mEnv;
		amEnv  = amDepth  * mEnv;
		ampEnv = EnvGen.kr(
			Env.new([0, 1, 0], [attack, max(0.01, ampDecay)], [ampAtkCurve, ampDecCurve]),
			doneAction: Done.freeSelf
		);
		cut = EnvGen.kr(Env.asr(0, 1, 0.006, \lin), gate, doneAction: Done.freeSelf);
		o4 = SinOscFB.ar(freq * r4, feedback) * lvl4;
		o3 = SinOsc.ar(freq * r3, modEnv * (m43 * o4)) * lvl3;
		o2 = SinOsc.ar(freq * r2, modEnv * (m42 * o4 + m32 * o3)) * lvl2;
		o1 = SinOsc.ar(freq * r1, modEnv * (m41 * o4 + m31 * o3 + m21 * o2)) * lvl1;
		o3 = o3 * (1 + (amEnv * (a43 * o4)));
		o3 = o3 * (1 + (amEnv * (g43 * (o4 - 1))));
		o2 = o2 * (1 + (amEnv * (a42 * o4 + a32 * o3)));
		o2 = o2 * (1 + (amEnv * (g42 * (o4 - 1) + g32 * (o3 - 1))));
		o1 = o1 * (1 + (amEnv * (a41 * o4 + a31 * o3 + a21 * o2)));
		o1 = o1 * (1 + (amEnv * (g41 * (o4 - 1) + g31 * (o3 - 1) + g21 * (o2 - 1))));
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
