routerAdd("POST", "/api/workshop/register", (e) => {
  e.response.header().set("Cache-Control", "no-store")
  e.response.header().set("Pragma", "no-cache")

  const fail = (status, code, message, fields) => {
    return e.json(status, {
      code: code,
      message: message,
      fields: fields || {},
    })
  }

  let inventory
  try {
    const inventoryPath = $os.getenv("WORKSHOP_SLOTS_FILE") || "/portal-config/slots.json"
    inventory = JSON.parse(toString($os.readFile(inventoryPath)))
  } catch (error) {
    console.log("student access inventory could not be read: " + error)
    return fail(503, "PORTAL_UNAVAILABLE", "Workspace assignment is temporarily unavailable.")
  }

  if (!Array.isArray(inventory) || inventory.length === 0) {
    return fail(503, "PORTAL_UNAVAILABLE", "No workshop workspaces are configured.")
  }

  const slots = []
  const slotNumbers = {}
  for (let i = 0; i < inventory.length; i++) {
    const item = inventory[i] || {}
    const match = /^s([0-9]{2,})$/.exec(String(item.student_number || ""))
    const slot = match ? parseInt(match[1], 10) : 0
    const url = String(item.workspace_url || "")
    const password = String(item.workspace_password || "")

    if (!slot || slotNumbers[slot] || !/^https:\/\//.test(url) || !password) {
      console.log("student access inventory contains an invalid or duplicate slot")
      return fail(503, "PORTAL_UNAVAILABLE", "The workspace inventory is invalid.")
    }

    slotNumbers[slot] = true
    slots.push({
      slot: slot,
      student_number: item.student_number,
      workspace_url: url,
      workspace_password: password,
    })
  }
  slots.sort((a, b) => a.slot - b.slot)

  const body = e.requestInfo().body || {}
  const name = String(body.name || "").trim()
  const email = String(body.email || "").trim().toLowerCase()
  const fields = {}

  if (!name || name.length > 100) {
    fields.name = "Enter a name between 1 and 100 characters."
  }
  if (!email || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    fields.email = "Enter a valid email address."
  }
  if (Object.keys(fields).length > 0) {
    return fail(400, "INVALID_INPUT", "Check the highlighted fields.", fields)
  }

  let assignment = null
  try {
    e.app.runInTransaction((txApp) => {
      const existing = txApp.findRecordsByFilter(
        "registrations",
        "email:lower = {:email}",
        "",
        1,
        0,
        { email: email },
      )

      if (existing.length > 0) {
        if (existing[0].getBool("resetting")) {
          throw new Error("WORKSPACE_RESETTING")
        }
        assignment = {
          slot: existing[0].getInt("slot"),
          returning: true,
        }
        return
      }

      const claimedRecords = txApp.findRecordsByFilter("registrations", "", "", 0, 0)
      const claimed = {}
      for (let i = 0; i < claimedRecords.length; i++) {
        claimed[claimedRecords[i].getInt("slot")] = true
      }

      let selected = null
      for (let i = 0; i < slots.length; i++) {
        if (!claimed[slots[i].slot]) {
          selected = slots[i]
          break
        }
      }
      if (!selected) {
        throw new Error("WORKSHOP_FULL")
      }

      const collection = txApp.findCollectionByNameOrId("registrations")
      const record = new Record(collection)
      record.set("name", name)
      record.set("email", email)
      record.set("slot", selected.slot)
      txApp.save(record)

      assignment = {
        slot: selected.slot,
        returning: false,
      }
    })
  } catch (error) {
    if (String(error).indexOf("WORKSPACE_RESETTING") !== -1) {
      return fail(409, "WORKSPACE_RESETTING", "This workspace is being reset. Please ask an instructor for help.")
    }
    if (String(error).indexOf("WORKSHOP_FULL") !== -1) {
      return fail(409, "WORKSHOP_FULL", "Every workshop space has already been assigned. Please ask an instructor for help.")
    }
    // PocketBase's email field is stricter than the form's basic syntax check.
    // Keep invalid submissions a client error without exposing storage details.
    if (String(error).indexOf("email: must be a valid email address") !== -1) {
      return fail(400, "INVALID_INPUT", "Check the highlighted fields.", { email: "Enter a valid email address." })
    }
    console.log("student access registration failed: " + error)
    return fail(503, "PORTAL_UNAVAILABLE", "Workspace assignment is temporarily unavailable.")
  }

  let selected = null
  for (let i = 0; i < slots.length; i++) {
    if (slots[i].slot === assignment.slot) {
      selected = slots[i]
      break
    }
  }
  if (!selected) {
    return fail(503, "ASSIGNMENT_UNAVAILABLE", "Your assigned workspace is no longer in the current inventory. Please ask an instructor for help.")
  }

  return e.json(200, {
    student_number: selected.student_number,
    workspace_url: selected.workspace_url,
    workspace_password: selected.workspace_password,
    returning: assignment.returning,
  })
})
