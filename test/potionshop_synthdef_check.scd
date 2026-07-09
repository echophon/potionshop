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
		atk1 = 0.001, dec1 = 0.4, atkCurve1 = -4, decCurve1 = -4,
		atk2 = 0.001, dec2 = 0.2, atkCurve2 = -4, decCurve2 = -4,
		atk3 = 0.001, dec3 = 0.2, atkCurve3 = -4, decCurve3 = -4,
		atk4 = 0.001, dec4 = 0.2, atkCurve4 = -4, decCurve4 = -4,
		gate = 1, pan = 0, detune = 0;
		var e1, e2, e3, e4, cut, free, maxTime, o2, o3, o4, sig;
		var o1mod, o1L, o1R, dUp, dDn, o1amA, o1amG, restSig, op1sig, halfW;
		e1 = EnvGen.kr(Env.new([0, 1, 0], [atk1, max(0.01, dec1)], [atkCurve1, decCurve1]));
		e2 = EnvGen.kr(Env.new([0, 1, 0], [atk2, max(0.01, dec2)], [atkCurve2, decCurve2]));
		e3 = EnvGen.kr(Env.new([0, 1, 0], [atk3, max(0.01, dec3)], [atkCurve3, decCurve3]));
		e4 = EnvGen.kr(Env.new([0, 1, 0], [atk4, max(0.01, dec4)], [atkCurve4, decCurve4]));
		cut = EnvGen.kr(Env.asr(0, 1, 0.006, \lin), gate, doneAction: Done.freeSelf);
		maxTime = max(max(atk1 + dec1, atk2 + dec2), max(atk3 + dec3, atk4 + dec4));
		free = EnvGen.kr(Env.new([0, 1], [maxTime + 0.05], \lin), doneAction: Done.freeSelf);
		o4 = SinOscFB.ar(freq * r4, feedback) * lvl4 * e4;
		o3 = SinOsc.ar(freq * r3, modIndex * (m43 * o4)) * lvl3 * e3;
		o2 = SinOsc.ar(freq * r2, modIndex * (m42 * o4 + m32 * o3)) * lvl2 * e2;
		// op1 stereo widening: two detuned clones, hard L/R, half gain each.
		dUp = (detune / 100).midiratio;
		dDn = (detune.neg / 100).midiratio;
		o1mod = modIndex * (m41 * o4 + m31 * o3 + m21 * o2);
		o1L = SinOsc.ar(freq * r1 * dDn, o1mod) * lvl1 * e1;
		o1R = SinOsc.ar(freq * r1 * dUp, o1mod) * lvl1 * e1;
		o3 = o3 * (1 + (amDepth * (a43 * o4)));
		o3 = o3 * (1 + (amDepth * (g43 * (o4 - 1))));
		o2 = o2 * (1 + (amDepth * (a42 * o4 + a32 * o3)));
		o2 = o2 * (1 + (amDepth * (g42 * (o4 - 1) + g32 * (o3 - 1))));
		o1amA = 1 + (amDepth * (a41 * o4 + a31 * o3 + a21 * o2));
		o1amG = 1 + (amDepth * (g41 * (o4 - 1) + g31 * (o3 - 1) + g21 * (o2 - 1)));
		o1L = o1L * o1amA * o1amG;
		o1R = o1R * o1amA * o1amG;
		restSig = Pan2.ar((c2 * o2) + (c3 * o3) + (c4 * o4), pan);
		halfW = (detune / 62).clip(0, 1);   // op1 clones spread AROUND pan (Option A)
		op1sig = Pan2.ar(c1 * o1L * 0.5, (pan - halfW).clip(-1, 1))
		       + Pan2.ar(c1 * o1R * 0.5, (pan + halfW).clip(-1, 1));
		sig = (restSig + op1sig) * cut * amp * 0.5;
		Out.ar(out, sig);
	}),
	// per-channel strip: DJ filter (non-resonant Butterworth LPF -> HPF in series,
	// one bipolar position) (mirror of PotionChannel).
	SynthDef("PotionChannel", { arg in = 0, out = 0, filterPos = 0;
		var sig, pos, lpCut, hpCut;
		sig = In.ar(in, 2);
		pos = Lag.kr(filterPos, 0.05).clip(-1, 1);
		lpCut = pos.min(0).neg.linexp(0, 1, 20000, 60).clip(60, 20000);
		hpCut = pos.max(0).linexp(0, 1, 20, 12000).clip(20, 12000);
		sig = LPF.ar(sig, lpCut);
		sig = HPF.ar(sig, hpCut);
		Out.ar(out, sig);
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
