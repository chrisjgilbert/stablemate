import { Controller } from "@hotwired/stimulus"

// Minimal modal/dialog: removes the dialog element on close (the generate-key
// modal is shown once, so dismissing it just removes it from the DOM). Also
// closes on backdrop click and Escape. (phase-3 generate-key modal)
export default class extends Controller {
  static targets = ["backdrop"]

  close() {
    this.element.remove()
  }

  // Wired declaratively via data-action on the backdrop (click->dialog#backdropClick)
  // so Stimulus binds/unbinds it for us — no manual addEventListener to leak.
  backdropClick(event) {
    if (event.target === this.backdropTarget) this.close()
  }

  connect() {
    this._onKeydown = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }
}
