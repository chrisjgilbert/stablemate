import { Controller } from "@hotwired/stimulus"

// Removes the dialog element on close — the generate-key modal is shown once, so
// dismissing it just removes it from the DOM.
export default class extends Controller {
  static targets = ["backdrop"]

  close() {
    this.element.remove()
  }

  // Wired declaratively via data-action on the backdrop so Stimulus binds and
  // unbinds it for us — no manual addEventListener to leak.
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
