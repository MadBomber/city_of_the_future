(function() {
  "use strict";

  // --- State ---

  var calls = {};
  var genCount = 0;
  var approvedCount = 0;
  var rejectedCount = 0;

  // Map coordinates for known locations
  var locationMap = {
    "4th and main":       { x: 80,  y: 60  },
    "oak street and 12th": { x: 240, y: 120 },
    "oak and 12th":       { x: 240, y: 120 },
    "200 elm":            { x: 140, y: 180 },
    "elm street":         { x: 140, y: 180 },
    "industrial":         { x: 300, y: 240 },
    "7th and pine":       { x: 160, y: 50  },
    "downtown":           { x: 200, y: 150 },
    "central square":     { x: 200, y: 150 },
    "parking garage":     { x: 220, y: 130 },
    "community center":   { x: 70,  y: 210 },
    "westside":           { x: 70,  y: 210 },
    "financial district": { x: 280, y: 90  },
    "5th avenue":         { x: 280, y: 90  }
  };

  var deptColors = {
    "Fire":        "#ff4444",
    "Police":      "#4488ff",
    "EMS":         "#44bb44",
    "Utilities":   "#ffaa44",
    "CityCouncil": "#ffffff"
  };

  var deptTotals = { "Fire": 5, "Police": 4, "EMS": 3, "Utilities": 2, "CityCouncil": 1 };

  // --- SSE Connection ---

  var evtSource = new EventSource("/events");

  evtSource.onmessage = function(e) {
    var evt = JSON.parse(e.data);
    handleEvent(evt);
  };

  evtSource.onerror = function() {
    evtSource.close();
    setTimeout(function() {
      location.reload();
    }, 2000);
  };

  // --- Stats Polling ---

  setInterval(fetchStats, 2000);

  function fetchStats() {
    fetch("/stats")
      .then(function(r) { return r.json(); })
      .then(function(stats) {
        var pub = 0, del = 0, nack = 0, dlq = 0;
        for (var ch in stats) {
          pub  += stats[ch].published || 0;
          del  += stats[ch].delivered || 0;
          nack += stats[ch].nacked    || 0;
          dlq  += stats[ch].dlq_depth || 0;
        }
        setText("stat-published", pub);
        setText("stat-delivered", del);
        setText("stat-nacked", nack);
        setText("stat-dlq", dlq);
      })
      .catch(function() {});
  }

  // --- Event Router ---

  function handleEvent(evt) {
    switch (evt.type) {
      case "phase_change":
        handlePhaseChange(evt);
        break;
      case "incoming_call":
        handleIncomingCall(evt);
        break;
      case "dispatch":
        handleDispatch(evt);
        break;
      case "field_report":
        handleFieldReport(evt);
        break;
      case "dept_status":
        handleDeptStatus(evt);
        break;
      case "escalation":
      case "escalation_event":
        handleEscalation(evt);
        break;
      case "method_missing":
        handleMethodMissing(evt);
        break;
      case "method_installed":
        handleMethodInstalled(evt);
        break;
      case "method_rejected":
        handleMethodRejected(evt);
        break;
      case "capability_reused":
        addEventLine(evt.timestamp, "governance", "REUSED: " + evt.data.target_class + "#" + evt.data.method_name + " for " + evt.data.call_id);
        break;
      case "escalation_analysis":
        handleEscalationAnalysis(evt);
        break;
      case "method_gen_failed":
        addEventLine(evt.timestamp, "method", "Generation failed: " + evt.data.method);
        break;
      case "budget_request":
        addEventLine(evt.timestamp, "escalation", evt.data.department + " requests budget increase — all units committed (" + evt.data.call_id + ")");
        break;
      case "budget_tabled":
        addEventLine(evt.timestamp, "governance", "City Council: " + evt.data.message);
        break;
      case "adaptation_success":
        handleAdaptationSuccess(evt);
        break;
      case "governance_event":
        handleGovernanceEvent(evt);
        break;
      case "call_resolved":
        handleCallResolved(evt);
        break;
      case "voice_spoken":
        addEventLine(evt.timestamp, "system", (evt.data.department || "System") + ': "' + truncate(evt.data.text, 60) + '"');
        break;
      default:
        addEventLine(evt.timestamp, "system", evt.type + ": " + JSON.stringify(evt.data).substring(0, 80));
    }
  }

  // --- Event Handlers ---

  function handlePhaseChange(evt) {
    var el = document.getElementById("phase-indicator");
    el.textContent = evt.data.phase;
    el.classList.add("active");
    addEventLine(evt.timestamp, "phase", "=== " + evt.data.phase + " ===");
  }

  function handleIncomingCall(evt) {
    var d = evt.data;
    calls[d.call_id] = {
      call_id: d.call_id,
      caller: d.caller,
      location: d.location,
      description: d.description,
      severity: d.severity,
      department: null,
      status: "incoming",
      unit_id: null
    };
    addEventLine(evt.timestamp, "call", d.call_id + " " + d.caller + ": " + truncate(d.description, 50));
    renderCalls();
    addMapMarker(d.call_id, d.location, "#ff44ff");
  }

  function handleDispatch(evt) {
    var d = evt.data;
    if (calls[d.call_id]) {
      calls[d.call_id].department = d.department;
      calls[d.call_id].unit_id = d.unit_id;
      calls[d.call_id].status = "dispatched";
      var color = deptColors[d.department] || "#aaaacc";
      updateMapMarker(d.call_id, color);
    }
    addEventLine(evt.timestamp, "dispatch", d.department + " " + d.unit_id + " → " + d.call_id);
    renderCalls();
  }

  function handleFieldReport(evt) {
    var d = evt.data;
    if (calls[d.call_id]) {
      calls[d.call_id].status = d.status;
      calls[d.call_id].department = d.department;
      calls[d.call_id].unit_id = d.unit_id;
    }
    addEventLine(evt.timestamp, "dispatch", d.department + " " + d.unit_id + ": " + d.status);
    renderCalls();
  }

  function handleDeptStatus(evt) {
    var d = evt.data;
    var total = deptTotals[d.department] || (d.available_units + d.active_calls);
    var utilization = total > 0 ? d.active_calls / total : 0;
    updateDeptRow(d.department, d.active_calls, total, utilization);
  }

  function handleEscalation(evt) {
    var d = evt.data;
    if (calls[d.call_id]) {
      calls[d.call_id].status = "escalated";
    }
    addEventLine(evt.timestamp, "escalation", d.call_id + ": " + truncate(d.reason, 60));
    renderCalls();
    updateMapMarker(d.call_id, "#ff44ff");
  }

  function handleMethodMissing(evt) {
    var d = evt.data;
    addEventLine(evt.timestamp, "method", "method_missing: " + d.class + "#" + d.method);
    genCount++;
    setText("gen-count", genCount);
  }

  function handleMethodInstalled(evt) {
    var d = evt.data;
    addEventLine(evt.timestamp, "governance", "APPROVED: " + d.class + "#" + d.method);
    approvedCount++;
    setText("approved-count", approvedCount);

    if (d.source) {
      var container = document.getElementById("generated-code");
      var entry = document.createElement("div");
      entry.className = "generated-entry";

      var header = document.createElement("div");
      header.className = "generated-entry-header";
      header.textContent = d.class + "#" + d.method;

      var pre = document.createElement("pre");
      var code = document.createElement("code");
      code.textContent = d.source;
      pre.appendChild(code);

      entry.appendChild(header);
      entry.appendChild(pre);
      container.appendChild(entry);
    }
  }

  function handleMethodRejected(evt) {
    var d = evt.data;
    addEventLine(evt.timestamp, "governance", "REJECTED: " + d.class + "#" + d.method);
    rejectedCount++;
    setText("rejected-count", rejectedCount);
  }

  function handleEscalationAnalysis(evt) {
    var d = evt.data;
    addEventLine(evt.timestamp, "method", "Generating: " + d.target_class + "#" + d.method_name);
    genCount++;
    setText("gen-count", genCount);
  }

  function handleAdaptationSuccess(evt) {
    var d = evt.data;
    if (calls[d.call_id]) {
      calls[d.call_id].status = "adapted";
      calls[d.call_id].department = d.target_class;
    }
    addEventLine(evt.timestamp, "governance", "ADAPTED: " + d.call_id + " via " + d.target_class + "#" + d.method);
    renderCalls();
    updateMapMarker(d.call_id, "#44ffaa");
  }

  function handleCallResolved(evt) {
    var d = evt.data;
    if (calls[d.call_id]) {
      calls[d.call_id].status = "resolved";
    }
    addEventLine(evt.timestamp, "dispatch", d.department + " " + d.unit_id + " resolved " + d.call_id);
    renderCalls();
    updateMapMarker(d.call_id, "#2a2a4a");
  }

  function handleGovernanceEvent(evt) {
    var d = evt.data;
    var tag = d.decision === "approved" || d.decision === ":approved" ? "governance" : "escalation";
    addEventLine(evt.timestamp, tag, d.decision + ": " + truncate(d.reason, 50));
  }

  // --- Render Functions ---

  function renderCalls() {
    var container = document.getElementById("calls-list");
    container.innerHTML = "";
    var ids = Object.keys(calls).reverse();
    for (var i = 0; i < ids.length; i++) {
      var c = calls[ids[i]];
      var div = document.createElement("div");
      div.className = "call-card " + statusClass(c);

      var deptLabel = c.department || "???";
      var statusText = c.unit_id ? c.unit_id + " " + c.status : c.status;

      div.innerHTML =
        '<div><span class="call-id">' + c.call_id + '</span>' +
        '<span class="call-dept">' + deptLabel + '</span></div>' +
        '<div class="call-desc">' + truncate(c.description, 60) + '</div>' +
        '<div class="call-status">' + statusText + '</div>';
      container.appendChild(div);
    }
  }

  function statusClass(call) {
    if (call.status === "adapted") return "adapted";
    if (call.status === "escalated") return "escalated";
    if (call.status === "resolved") return "resolved";
    if (!call.department) return "unknown";
    var d = call.department.toLowerCase();
    if (d === "fire") return "fire";
    if (d === "police") return "police";
    if (d === "ems") return "ems";
    if (d === "utilities") return "utilities";
    return "unknown";
  }

  function updateDeptRow(name, active, total, utilization) {
    var row = document.querySelector('.dept-row[data-dept="' + name + '"]');
    if (!row) return;
    var fill = row.querySelector(".dept-fill");
    var units = row.querySelector(".dept-units");
    fill.style.width = (utilization * 100) + "%";
    units.textContent = active + "/" + total;
  }

  function addEventLine(timestamp, tag, text) {
    var container = document.getElementById("event-stream");
    var div = document.createElement("div");
    div.className = "event-line";

    var time = timestamp || new Date().toLocaleTimeString();
    if (time.length > 12) time = time.substring(0, 12);

    div.innerHTML =
      '<span class="event-time">' + time + '</span>' +
      '<span class="event-tag ' + tag + '">' + tag.toUpperCase() + '</span>' +
      '<span class="event-text">' + escapeHtml(text) + '</span>';
    container.appendChild(div);

    // Keep last 100 events visible
    while (container.children.length > 100) {
      container.removeChild(container.firstChild);
    }
    container.scrollTop = container.scrollHeight;
  }

  // --- Map Functions ---

  function locationToCoords(location) {
    if (!location) return { x: 200, y: 150 };
    var loc = location.toLowerCase();
    for (var key in locationMap) {
      if (loc.indexOf(key) !== -1) return locationMap[key];
    }
    // Hash the location string to get a pseudo-random but stable position
    var hash = 0;
    for (var i = 0; i < loc.length; i++) {
      hash = ((hash << 5) - hash) + loc.charCodeAt(i);
      hash |= 0;
    }
    return {
      x: 60 + Math.abs(hash % 280),
      y: 40 + Math.abs((hash >> 8) % 220)
    };
  }

  function addMapMarker(callId, location, color) {
    var svg = document.getElementById("map-markers");
    var coords = locationToCoords(location);

    var g = document.createElementNS("http://www.w3.org/2000/svg", "g");
    g.setAttribute("class", "map-marker");
    g.setAttribute("data-call", callId);

    var circle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    circle.setAttribute("cx", coords.x);
    circle.setAttribute("cy", coords.y);
    circle.setAttribute("r", "6");
    circle.setAttribute("fill", color);
    circle.setAttribute("stroke", color);
    circle.setAttribute("fill-opacity", "0.4");
    circle.classList.add("map-pulse");

    var label = document.createElementNS("http://www.w3.org/2000/svg", "text");
    label.setAttribute("x", coords.x + 10);
    label.setAttribute("y", coords.y + 3);
    label.textContent = callId;

    g.appendChild(circle);
    g.appendChild(label);
    svg.appendChild(g);
  }

  function updateMapMarker(callId, color) {
    var marker = document.querySelector('.map-marker[data-call="' + callId + '"] circle');
    if (marker) {
      marker.setAttribute("fill", color);
      marker.setAttribute("stroke", color);
      marker.classList.remove("map-pulse");
    }
  }

  // --- Utilities ---

  function truncate(s, n) {
    if (!s) return "";
    return s.length > n ? s.substring(0, n) + "..." : s;
  }

  function setText(id, val) {
    var el = document.getElementById(id);
    if (el) el.textContent = val;
  }

  function escapeHtml(s) {
    var div = document.createElement("div");
    div.textContent = s;
    return div.innerHTML;
  }

  // --- Random Scenario Pools ---

  var callerNames = [
    "Maria Santos", "James Wilson", "Lisa Chen", "Tom Bradley", "Derek Nguyen",
    "Sarah Johnson", "Mike Rivera", "Angela Park", "David Thompson", "Rosa Martinez",
    "Kevin O'Brien", "Priya Sharma", "Carlos Mendez", "Nina Volkov", "Jamal Washington",
    "Helen Kim", "Frank DeLuca", "Yuki Tanaka", "Omar Hassan", "Bridget Murphy"
  ];

  var locations = [
    "4th and Main Street", "Oak Street and 12th Avenue", "200 Elm Street",
    "Industrial Boulevard", "Downtown, Central Square", "7th and Pine",
    "Financial District, 5th Avenue", "Westside Community Center",
    "Parking garage on Oak", "300 block of Maple Drive",
    "Corner of Broadway and 3rd", "Riverside Park", "The waterfront district",
    "Near City Hall", "Highway 9 overpass"
  ];

  var scenarios = {
    fire: {
      severity: ["high", "critical", "high", "medium"],
      descriptions: [
        "There's smoke pouring out of the building! The whole second floor is on fire!",
        "A kitchen fire at Romano's restaurant has spread to the dining room! People are evacuating!",
        "Electrical fire in apartment 4B! Sparks shooting from the walls and the smoke is thick!",
        "Car fire on the highway! The engine is fully engulfed and it's spreading to the grass!",
        "The old warehouse on Industrial is on fire! There might be chemicals stored inside!",
        "A dumpster fire behind the grocery store has spread to the building! The wall is burning!",
        "Lightning struck a house on Maple and the roof is on fire! Family is still inside!",
        "Grease fire at the food truck festival! Multiple vendors affected, crowd panicking!",
        "Gas station pump is on fire! Everyone's running and I can hear small explosions!",
        "Apartment building fire! Smoke is coming from multiple floors, people on the fire escapes!"
      ]
    },
    police: {
      severity: ["critical", "high", "critical", "high"],
      descriptions: [
        "Someone just robbed the corner store! They had a gun and ran east on Oak!",
        "There's a fight outside the bar on Broadway! One guy pulled a knife!",
        "I just witnessed a hit and run! Silver SUV took off heading north on 5th!",
        "Someone is breaking into the house across the street right now! I can see them in the window!",
        "Road rage incident on Highway 9! Two drivers are out of their cars screaming, one has a bat!",
        "There's a man acting erratic at Central Square, screaming at people and throwing things!",
        "Car chase through downtown! A pickup truck just blew through two red lights!",
        "Bank robbery in progress at First National! Multiple suspects, they blocked the doors!",
        "Gunshots near the park! People are running and screaming, I'm hiding behind a car!",
        "Shoplifter at the electronics store pulled a weapon on the security guard!"
      ]
    },
    ems: {
      severity: ["critical", "high", "critical", "high"],
      descriptions: [
        "My husband is having chest pains! He's sweating and can't breathe!",
        "Someone collapsed on the sidewalk! They're not responding and I can't find a pulse!",
        "Bad car accident at the intersection! Driver is trapped and bleeding from the head!",
        "My daughter is having a severe allergic reaction! Her throat is swelling shut!",
        "Construction worker fell from the scaffolding! He's conscious but can't move his legs!",
        "Elderly woman found unconscious in her apartment! She's breathing but won't wake up!",
        "Kid at the pool isn't breathing! Lifeguard is doing CPR right now!",
        "Man having a seizure on the bus! He hit his head on the way down, there's blood everywhere!",
        "Pregnant woman in labor at the grocery store! The baby is coming fast, she can't move!",
        "Cyclist was hit by a car! They're in the road, leg is bent the wrong way!"
      ]
    },
    utilities: {
      severity: ["medium", "high", "medium", "high"],
      descriptions: [
        "There's water shooting up from the street! A pipe must have burst!",
        "Strong gas smell in the whole neighborhood! My detector is going off!",
        "Power is out for the entire block and I can see sparks at the transformer on the pole!",
        "Sewer is backing up into the basement! The whole street smells terrible!",
        "A tree fell on the power lines! They're sparking on the ground, blocking the road!",
        "A car knocked over a hydrant and water is flooding the intersection!",
        "The water coming out of our taps is brown! The whole building is affected!",
        "Manhole cover blew off and steam is shooting 20 feet in the air!",
        "Street light pole is leaning and about to fall! The base is completely corroded!",
        "Underground electrical vault is smoking! I can see flames through the grate!"
      ]
    },
    unknown: {
      severity: ["critical", "high", "critical", "high"],
      descriptions: [
        "There are drones everywhere downtown! Hundreds of them dropping papers!",
        "Something just opened in the sky above Central Square! It's like a hole in the air with light pouring through and things are coming out of it! This is like that New York attack!",
        "The ground is shaking and a massive sinkhole just opened up on Elm Street! Cars are falling in!",
        "Strange glowing fog is rolling down Main Street! Everyone who walks into it comes out confused and can't remember who they are!",
        "There's a swarm of something flying over downtown! They're not birds, they're too big and they're metallic! They're landing on buildings!",
        "Giant creatures are coming out of the river! They look like armored centipedes the size of buses! People are running!",
        "Some kind of portal opened at the park and armored figures are marching through! They've got weapons I've never seen before! It's an invasion!",
        "Every car on 5th Avenue just stopped working at the same time! Electronics are dead, nothing turns on! Something is jamming everything!",
        "A beam of light just hit the clock tower and now there's a force field expanding from it! It's pushing everything outward!",
        "Something crashed in the financial district! It's not a plane, it's some kind of craft and it's still glowing! Figures are emerging from it!"
      ]
    }
  };

  function randomFrom(arr) {
    return arr[Math.floor(Math.random() * arr.length)];
  }

  function randomScenario(type) {
    var pool = scenarios[type];
    return {
      caller:      randomFrom(callerNames),
      location:    randomFrom(locations),
      description: randomFrom(pool.descriptions),
      severity:    randomFrom(pool.severity)
    };
  }

  // --- Quick Call Buttons ---

  var quickButtons = document.querySelectorAll(".quick-call");
  for (var i = 0; i < quickButtons.length; i++) {
    quickButtons[i].addEventListener("click", function() {
      var btn = this;
      var type = btn.getAttribute("data-type");
      var payload = randomScenario(type);

      fetch("/calls", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      })
      .then(function(r) { return r.json(); })
      .then(function(data) {
        addEventLine(new Date().toLocaleTimeString(), "system", "Submitted " + data.call_id);
      })
      .catch(function(err) {
        addEventLine(new Date().toLocaleTimeString(), "system", "Submit failed: " + err);
      });
    });
  }

  // Initial event
  addEventLine(new Date().toLocaleTimeString(), "system", "Dashboard connected");
})();
