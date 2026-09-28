migrate((app) => {
  const collection = new Collection({
    type: "base",
    name: "registrations",
    listRule: null,
    viewRule: null,
    createRule: null,
    updateRule: null,
    deleteRule: null,
    fields: [
      {
        name: "name",
        type: "text",
        required: true,
        min: 1,
        max: 100,
      },
      {
        name: "email",
        type: "email",
        required: true,
      },
      {
        name: "slot",
        type: "number",
        required: true,
        min: 1,
        onlyInt: true,
      },
    ],
    indexes: [
      "CREATE UNIQUE INDEX idx_registrations_email ON registrations (email)",
      "CREATE UNIQUE INDEX idx_registrations_slot ON registrations (slot)",
    ],
  })

  app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("registrations")
  app.delete(collection)
})
