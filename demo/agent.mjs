// One scripted "agent" for the demo (demo/record.ps1): it reads its app with sidehand, then types
// and clicks through the form from behind the user's note, and logs where it works so the live
// view (DemoApps.cs, role live) can draw its pointer and text caret.
//   node demo/agent.mjs <orders|expense|mail> <events file> [start delay ms]
// Run three at once: each has its own PowerShell worker and its own ref cache.
import { appendFileSync } from "node:fs";
import * as cmd from "../lib/commands.mjs";
import { useWorker } from "../lib/powershell.mjs";

// role, name, action, value, what the agent says it is doing. "keys" types the text key by key.
// SIDEHAND_DEMO_LANG=ko matches the Korean demo apps (DemoApps.cs).
const KO = process.env.SIDEHAND_DEMO_LANG === "ko";
const PLANS_KO = {
	orders: {
		title: "Contoso 주문",
		result: "주문 완료",
		done: "완료: 주문 제출",
		steps: [
			["Edit", "고객", "keys", "Blue-B Studio", "고객 이름 입력 중"],
			["Edit", "수량", "keys", "3", "수량 입력 중"],
			["ComboBox", "지역", "select", "제주", "지역 고르는 중"],
			["CheckBox", "특급 배송", "check", "", "특급 배송 체크 중"],
			["Button", "주문 제출", "click", "", "주문 제출 중"],
		],
	},
	expense: {
		title: "경비 보고서",
		result: "결재 요청",
		done: "완료: 결재 요청",
		steps: [
			["Edit", "거래처", "keys", "제주항공", "거래처 입력 중"],
			["Edit", "금액 (원)", "keys", "184,000", "금액 입력 중"],
			["ComboBox", "분류", "select", "출장", "분류 고르는 중"],
			["CheckBox", "영수증 첨부", "check", "", "영수증 체크 중"],
			["Edit", "메모", "keys", "제주 고객 미팅 항공권", "메모 입력 중"],
			["Button", "결재 올리기", "click", "", "결재 올리는 중"],
		],
	},
	mail: {
		title: "새 메일",
		result: "보냄",
		done: "완료: 메일 보냄",
		steps: [
			["Edit", "받는 사람", "keys", "minji@contoso.com", "주소 입력 중"],
			["Edit", "제목", "keys", "주문 2041 확인 완료", "제목 입력 중"],
			["Edit", "내용", "keys", "민지님, 주문하신 상품은 내일 특급으로 제주에 도착합니다. 감사합니다!", "내용 쓰는 중"],
			["Button", "보내기", "click", "", "보내는 중"],
		],
	},
};
const PLANS_EN = {
	orders: {
		title: "Contoso Orders",
		result: "Order submitted",
		done: "Done: order submitted",
		steps: [
			["Edit", "Customer", "keys", "Blue-B Studio", "Typing the customer"],
			["Edit", "Quantity", "keys", "3", "Typing the quantity"],
			["ComboBox", "Region", "select", "Jeju", "Choosing the region"],
			["CheckBox", "Express shipping", "check", "", "Ticking express shipping"],
			["Button", "Submit order", "click", "", "Submitting the order"],
		],
	},
	expense: {
		title: "Expense report",
		result: "Submitted",
		done: "Done: expense submitted",
		steps: [
			["Edit", "Vendor", "keys", "Jeju Air", "Typing the vendor"],
			["Edit", "Amount (KRW)", "keys", "184,000", "Typing the amount"],
			["ComboBox", "Category", "select", "Travel", "Choosing the category"],
			["CheckBox", "Receipt attached", "check", "", "Ticking the receipt box"],
			["Edit", "Memo", "keys", "Flight to the Jeju client meeting", "Typing the memo"],
			["Button", "Submit for approval", "click", "", "Submitting for approval"],
		],
	},
	mail: {
		title: "New message - Mail",
		result: "Sent to",
		done: "Done: message sent",
		steps: [
			["Edit", "To", "keys", "minji@contoso.com", "Typing the address"],
			["Edit", "Subject", "keys", "Order 2041 is confirmed", "Typing the subject"],
			["Edit", "Message", "keys", "Hi Minji, your order ships to Jeju by express tomorrow. Thanks!", "Writing the message"],
			["Button", "Send", "click", "", "Sending"],
		],
	},
};

const PLANS = KO ? PLANS_KO : PLANS_EN;
const [name, events, delay = "0"] = process.argv.slice(2);
const plan = PLANS[name];
if (!plan || !events) {
	console.error(`usage: node demo/agent.mjs <${Object.keys(PLANS).join("|")}> <events file> [start delay ms]`);
	process.exit(2);
}
useWorker(true); // one PowerShell per agent, with its own ref cache

const emit = (...f) => appendFileSync(events, `${f.join("\t")}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

await sleep(Number(delay));
emit("plan", plan.steps.length);
emit("state", KO ? "창 읽는 중" : "Reading the window");
const tree = (await cmd.tree({ title: plan.title, rects: true })).text;
const els = [...tree.matchAll(/^\s*(e\d+) (\w+) "([^"]*)".*?@(-?\d+),(-?\d+) (\d+)x(\d+)/gm)].map((m) => ({
	ref: m[1], role: m[2], name: m[3], x: +m[4], y: +m[5], w: +m[6], h: +m[7],
}));
const n = tree.split("\n").length - 1;
emit("state", KO ? `컨트롤 ${n}개 읽음` : `Read ${n} controls`);
await sleep(500);

let k = 0;
for (const [role, label, action, value, say] of plan.steps) {
	const el = els.find((e) => e.role === role && e.name === label);
	if (!el) throw new Error(`no ${role} "${label}" in ${plan.title}`);
	const x = action === "keys" ? el.x + Math.min(el.w * 0.3, 60) : el.x + el.w / 2;
	const y = el.y + Math.min(el.h / 2, 20);
	emit("state", say);
	emit("move", Math.round(x), Math.round(y));
	await sleep(520);
	if (action === "keys") {
		emit("focus", el.x, el.y, el.w, el.h);
		// press takes space-separated keys; a space itself is the key "space".
		await cmd.act({ ref: el.ref, action: "press", value: [...value].map((c) => (c === " " ? "space" : c)).join(" ") });
	} else {
		emit("focus");
		emit("click", Math.round(x), Math.round(y));
		await cmd.act({ ref: el.ref, action, value });
	}
	emit("step", ++k);
	await sleep(300);
}
emit("focus");
await cmd.wait({ title: plan.title, text: plan.result, timeoutMs: 5000 }); // throws if the app never confirms
emit("state", plan.done);
emit("done");
process.exit(0);
