import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "button"]

  copy() {
    const source = this.sourceTarget
    const text = (source.value ?? source.textContent ?? "").trim()
    navigator.clipboard.writeText(text)

    const button = this.hasButtonTarget ? this.buttonTarget : this.element
    const original = button.textContent
    button.textContent = "Copied"
    setTimeout(() => { button.textContent = original }, 1600)
  }
}
