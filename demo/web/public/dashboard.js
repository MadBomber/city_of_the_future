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
    setTimeout(function() {
      addEventLine("system", "system", "SSE reconnecting...");
    }, 1000);
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
      case "escalation_analysis":
        handleEscalationAnalysis(evt);
        break;
      case "method_gen_failed":
        addEventLine(evt.timestamp, "method", "Generation failed: " + evt.data.method);
        break;
      case "governance_event":
        handleGovernanceEvent(evt);
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
    updateDeptRow(d.department, d.available_units, total, d.capacity_pct);
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

  function updateDeptRow(name, available, total, pct) {
    var row = document.querySelector('.dept-row[data-dept="' + name + '"]');
    if (!row) return;
    var fill = row.querySelector(".dept-fill");
    var units = row.querySelector(".dept-units");
    fill.style.width = (pct * 100) + "%";
    units.textContent = available + "/" + total;
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

  // Initial event
  addEventLine(new Date().toLocaleTimeString(), "system", "Dashboard connected");
})();
