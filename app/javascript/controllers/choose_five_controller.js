import { Controller } from "@hotwired/stimulus"

// Enforces the "choose exactly N" rule on the downgrade picker (PRD §5.6): the
// submit button is disabled until precisely `limit` monitors are selected, and
// extra checkboxes are blocked once the limit is reached. Purely client-side
// affordance — the server re-validates the count, so this only smooths the UX.
export default class extends Controller {
  static targets = ["checkbox", "submit", "counter"]
  static values = { limit: Number }

  connect() {
    this.refresh()
  }

  toggle() {
    this.refresh()
  }

  refresh() {
    const selected = this.checkboxTargets.filter((cb) => cb.checked).length
    const atLimit = selected >= this.limitValue

    // Block selecting more than the limit.
    this.checkboxTargets.forEach((cb) => {
      cb.disabled = !cb.checked && atLimit
    })

    if (this.hasSubmitTarget) this.submitTarget.disabled = selected !== this.limitValue
    if (this.hasCounterTarget) {
      this.counterTarget.textContent = `${selected} / ${this.limitValue} selected`
    }
  }
}
