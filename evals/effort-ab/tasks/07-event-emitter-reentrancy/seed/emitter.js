'use strict';

/**
 * Small synchronous event emitter used by the job scheduler.
 *
 * Listeners run in registration order and are called with `this` bound to the
 * emitter. `on`, `once` and `off` return the emitter so calls can be chained.
 */
class Emitter {
  constructor() {
    // event name -> listener functions, in registration order
    this._events = new Map();
  }

  /** Register `fn` for `event`. */
  on(event, fn) {
    this._listenersOf(event).push(fn);
    return this;
  }

  /** Register `fn` for `event`; it is unregistered after it has run once. */
  once(event, fn) {
    const wrapper = (...args) => {
      fn.apply(this, args);
      this.off(event, wrapper);
    };
    return this.on(event, wrapper);
  }

  /** Remove a registration of `fn` for `event`. Unknown listeners are ignored. */
  off(event, fn) {
    const listeners = this._events.get(event);
    if (!listeners) {
      return this;
    }
    const index = listeners.indexOf(fn);
    if (index !== -1) {
      listeners.splice(index, 1);
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
    const listeners = this._events.get(event);
    if (!listeners || listeners.length === 0) {
      if (event === 'error') {
        throw args[0] instanceof Error ? args[0] : new Error('Unhandled error');
      }
      return false;
    }
    for (let i = 0; i < listeners.length; i++) {
      listeners[i].apply(this, args);
    }
    return true;
  }

  /** Number of registrations (on + once) currently held for `event`. */
  listenerCount(event) {
    const listeners = this._events.get(event);
    return listeners ? listeners.length : 0;
  }

  _listenersOf(event) {
    let listeners = this._events.get(event);
    if (!listeners) {
      listeners = [];
      this._events.set(event, listeners);
    }
    return listeners;
  }
}

module.exports = { Emitter };
