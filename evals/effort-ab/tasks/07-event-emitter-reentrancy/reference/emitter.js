'use strict';

/**
 * Small synchronous event emitter used by the job scheduler.
 *
 * Listeners run in registration order and are called with `this` bound to the
 * emitter. `on`, `once` and `off` return the emitter so calls can be chained.
 */
class Emitter {
  constructor() {
    // event name -> registrations ({ fn, once, fired }) in registration order
    this._events = new Map();
  }

  /** Register `fn` for `event`. */
  on(event, fn) {
    this._register(event, { fn, once: false, fired: false });
    return this;
  }

  /** Register `fn` for `event`; it is unregistered after it has run once. */
  once(event, fn) {
    this._register(event, { fn, once: true, fired: false });
    return this;
  }

  /**
   * Remove the most recently added registration (on or once) of `fn` for
   * `event`. Unknown listeners are ignored.
   */
  off(event, fn) {
    const registrations = this._events.get(event);
    if (!registrations) {
      return this;
    }
    for (let i = registrations.length - 1; i >= 0; i--) {
      if (registrations[i].fn === fn) {
        this._unregister(event, registrations[i]);
        break;
      }
    }
    return this;
  }

  /**
   * Call every listener of `event` with `args`.
   * Returns true when at least one listener ran, false otherwise.
   * An 'error' event that nobody listens for is thrown instead of dropped:
   * the first argument if it is an Error, otherwise a generic Error.
   */
  emit(event, ...args) {
    const registrations = this._events.get(event);
    if (!registrations || registrations.length === 0) {
      if (event === 'error') {
        throw args[0] instanceof Error ? args[0] : new Error('Unhandled error');
      }
      return false;
    }
    // Iterate a snapshot: listeners added or removed while this emit is in
    // flight only affect later emits.
    const snapshot = registrations.slice();
    let ran = false;
    for (const registration of snapshot) {
      if (registration.once) {
        if (registration.fired) {
          continue; // already consumed, e.g. by a re-entrant emit
        }
        registration.fired = true;
        this._unregister(event, registration); // before the callback runs
      }
      registration.fn.apply(this, args);
      ran = true;
    }
    return ran;
  }

  /** Number of registrations (on + once) currently held for `event`. */
  listenerCount(event) {
    const registrations = this._events.get(event);
    return registrations ? registrations.length : 0;
  }

  _register(event, registration) {
    let registrations = this._events.get(event);
    if (!registrations) {
      registrations = [];
      this._events.set(event, registrations);
    }
    registrations.push(registration);
  }

  _unregister(event, registration) {
    const registrations = this._events.get(event);
    if (!registrations) {
      return;
    }
    const index = registrations.indexOf(registration);
    if (index !== -1) {
      registrations.splice(index, 1);
    }
    if (registrations.length === 0) {
      this._events.delete(event);
    }
  }
}

module.exports = { Emitter };
