import { Controller } from "@hotwired/stimulus"

// Type-to-confirm delete gate (projects.md §6, §13-S4): the delete button stays
// disabled until the typed value exactly matches the project name. Purely a
// client-side affordance — ProjectsController#destroy re-validates the typed
// name server-side (belt-and-braces), so this only smooths the UX.
export default class extends Controller {
  static targets = ["input", "button"]
  static values = { name: String }

  connect() {
    this.check()
  }

  check() {
    this.buttonTarget.disabled = this.inputTarget.value !== this.nameValue
  }
}
