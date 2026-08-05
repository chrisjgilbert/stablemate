import { Controller } from "@hotwired/stimulus"

// Picking a preset writes its seconds value into the hidden field; picking
// "Custom" reveals a seconds input. The stored value is always seconds.
export default class extends Controller {
  static targets = ["select", "custom", "value"]

  connect() {
    this.update()
  }

  update() {
    const selected = this.selectTarget.value
    if (selected === "custom") {
      this.customTarget.classList.remove("hidden")
      this.valueTarget.value = this.customTarget.value
    } else {
      this.customTarget.classList.add("hidden")
      this.valueTarget.value = selected
    }
  }

  syncCustom() {
    this.valueTarget.value = this.customTarget.value
  }
}
