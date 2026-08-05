import { Controller } from "@hotwired/stimulus"

// Purely a client-side affordance — the server re-validates the count.
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

    this.checkboxTargets.forEach((cb) => {
      cb.disabled = !cb.checked && atLimit
    })

    if (this.hasSubmitTarget) this.submitTarget.disabled = selected !== this.limitValue
    if (this.hasCounterTarget) {
      this.counterTarget.textContent = `${selected} / ${this.limitValue} selected`
    }
  }
}
