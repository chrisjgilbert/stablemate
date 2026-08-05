import { Controller } from "@hotwired/stimulus"

// Purely a client-side affordance — ProjectsController#destroy re-validates the
// typed name server-side.
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
