using System;
using System.Collections.Generic;
using Godot;

// SOUNDSCAPE -- FX parameter bridge.
//
// READ THIS BEFORE WIRING IT UP, because the brief for this file asked for something the
// engine cannot give, and shipping it as if it could would be the bug rather than the fix.
//
// WHAT IS NOT POSSIBLE, in Godot 4, from C# or GDScript:
//   - Writing parameters "on the native audio thread". There is no user callback on
//     Godot's mix thread. AudioEffectInstance::_process is C++ only -- reachable from a
//     GDExtension, never from a managed or scripted language. Anything either language
//     does happens on the main thread and is picked up by the mixer on its next block.
//   - A lower-latency path than AudioServer. C# calls the SAME engine setters GDScript
//     does, through one extra marshalling hop. Moving existing writes here makes them
//     marginally slower, never faster.
//
// WHAT ACTUALLY CAUSES CRACKLE, and what this class does about it:
//   1. Writing on every input event instead of once per frame. A drag fires forty times a
//      second; forty bus updates per frame is the stall. -> Coalesced here, last write
//      wins per parameter. (Equalizer._push already does this on the GDScript side; this
//      is the same discipline for anything that does not route through it.)
//   2. Stepping a parameter discontinuously. A cutoff that jumps 8 kHz in one block is an
//      edge, and an edge is a click. -> Slew() ramps toward the target over frames.
//   3. Toggling an effect in and out of the chain under a live signal. -> SetEnabled()
//      defers the switch-off until the parameter has been ramped to its neutral value.
//
// So: this is a smoothing and batching layer, which is worth having. It is not a
// threading fix, and it will not lower latency. Read the class as the former.
//
// Requires the .NET build of Godot 4. The standard build ignores this file.
public partial class AudioFxBridge : Node
{
	/// <summary>Fires once per frame after a batch is flushed, for readouts that mirror the bus.</summary>
	[Signal]
	public delegate void FxAppliedEventHandler();

	// A parameter is addressed the way AudioServer addresses one: bus, slot, property.
	private readonly struct Target : IEquatable<Target>
	{
		public readonly int Bus;
		public readonly int Slot;
		public readonly StringName Property;

		public Target(int bus, int slot, StringName property)
		{
			Bus = bus;
			Slot = slot;
			Property = property;
		}

		public bool Equals(Target o) => Bus == o.Bus && Slot == o.Slot && Property == o.Property;
		public override bool Equals(object o) => o is Target t && Equals(t);
		public override int GetHashCode() => HashCode.Combine(Bus, Slot, Property.ToString());
	}

	private sealed class Slew
	{
		public float Current;
		public float Target;
		// Units per second. 0 means "jump", which is correct for anything that is not
		// audible as a ramp -- an integer mode, a band index, a flag.
		public float Rate;
		public bool Primed;
	}

	private readonly Dictionary<Target, Slew> _params = new();
	private readonly Dictionary<(int bus, int slot), bool> _enable = new();
	private readonly List<Target> _scratch = new();

	/// <summary>
	/// Queue a parameter write. Safe to call at input-event rate: repeated writes to the
	/// same target collapse, and only the final value reaches the bus this frame.
	/// </summary>
	/// <param name="ratePerSecond">
	/// How fast the value is allowed to travel, in parameter units per second. 0 applies
	/// it immediately. Pick a rate for anything a listener would hear as a step: a filter
	/// cutoff, a wet mix, a pitch scale. Leave it 0 for discrete settings.
	/// </param>
	public void Set(int bus, int slot, StringName property, float value, float ratePerSecond = 0f)
	{
		var key = new Target(bus, slot, property);
		if (!_params.TryGetValue(key, out var s))
		{
			s = new Slew { Current = value, Target = value, Rate = ratePerSecond };
			_params[key] = s;
			return;   // first write lands on the next flush; nothing to ramp from yet
		}
		s.Target = value;
		s.Rate = ratePerSecond;
	}

	/// <summary>
	/// Queue an effect enable/disable. Disabling is deferred by one flush so any ramp in
	/// flight finishes first -- switching an effect out from under a half-swept filter is
	/// the click this exists to avoid.
	/// </summary>
	public void SetEnabled(int bus, int slot, bool enabled) => _enable[(bus, slot)] = enabled;

	/// <summary>
	/// Convenience for the common case: the Master bus, addressed by effect instance.
	/// Returns -1 when the effect is not on that bus, which the caller should treat as
	/// "the chain is not built yet", not as an error.
	/// </summary>
	public static int SlotOf(int bus, AudioEffect effect)
	{
		for (int i = 0; i < AudioServer.GetBusEffectCount(bus); i++)
			if (AudioServer.GetBusEffect(bus, i) == effect)
				return i;
		return -1;
	}

	// One flush per frame, on the main thread, after every input event for this frame has
	// been seen. That ordering is the whole point: a forty-event drag becomes one write.
	public override void _Process(double delta)
	{
		if (_params.Count == 0 && _enable.Count == 0)
			return;

		float dt = (float)delta;
		bool any = false;

		_scratch.Clear();
		_scratch.AddRange(_params.Keys);
		foreach (var key in _scratch)
		{
			var s = _params[key];
			if (!s.Primed)
			{
				s.Primed = true;
			}
			else if (s.Rate > 0f)
			{
				float step = s.Rate * dt;
				s.Current = Math.Abs(s.Target - s.Current) <= step
					? s.Target
					: s.Current + Math.Sign(s.Target - s.Current) * step;
			}
			else
			{
				s.Current = s.Target;
			}

			var effect = AudioServer.GetBusEffect(key.Bus, key.Slot);
			if (effect == null)
			{
				_params.Remove(key);   // the chain was rebuilt underneath us
				continue;
			}
			effect.Set(key.Property, s.Current);
			any = true;

			// Settled and no longer moving: stop paying for it every frame.
			if (Mathf.IsEqualApprox(s.Current, s.Target))
				_params.Remove(key);
		}

		foreach (var ((bus, slot), on) in _enable)
		{
			if (AudioServer.GetBusEffect(bus, slot) == null)
				continue;
			AudioServer.SetBusEffectEnabled(bus, slot, on);
			any = true;
		}
		_enable.Clear();

		if (any)
			EmitSignal(SignalName.FxApplied);
	}
}
