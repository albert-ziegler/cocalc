/*
This is a renderer using pdf.js.
*/

import { throttle } from "underscore";
import misc from "smc-util/misc";
import { React, ReactDOM, rclass, rtypes } from "../smc-react";
import { Loading } from "../r_misc";
import { getDocument } from "./pdfjs-doc-cache";
import { raw_url } from "../code-editor/util";
import { Page } from "./pdfjs-page";

export let PDFJS = rclass({
    displayName: "LaTeXEditor-PDFJS",

    propTypes: {
        id: rtypes.string.isRequired,
        actions: rtypes.object.isRequired,
        editor_state: rtypes.immutable.Map,
        is_fullscreen: rtypes.bool,
        project_id: rtypes.string,
        path: rtypes.string,
        reload: rtypes.number,
        font_size: rtypes.number.isRequired,
        renderer: rtypes.string /* "canvas" or "svg" */
    },

    getDefaultProps() {
        return {
            renderer: "svg"
        };
    },

    getInitialState() {
        return {
            loaded: false,
            doc: { pdfInfo: { fingerprint: "" } }
        };
    },

    shouldComponentUpdate(next_props, next_state) {
        return (
            misc.is_different(this.props, next_props, [
                "reload",
                "font_size",
                "renderer",
                "path"
            ]) ||
            this.state.loaded != next_state.loaded ||
            this.state.doc.pdfInfo.fingerprint !=
                next_state.doc.pdfInfo.fingerprint
        );
    },

    render_loading() {
        return <Loading theme="medium" />;
    },

    on_scroll() {
        let elt = ReactDOM.findDOMNode(this.refs.scroll);
        if (!elt) return;
        elt = $(elt);
        const scroll = { top: elt.scrollTop(), left: elt.scrollLeft() };
        this.props.actions.save_editor_state(this.props.id, { scroll });
    },

    restore_scroll() {
        if (!this.props.editor_state) return;
        const scroll = this.props.editor_state.get("scroll");
        if (!scroll) return;
        let elt = ReactDOM.findDOMNode(this.refs.scroll);
        if (!elt) return;
        elt = $(elt);
        elt.scrollTop(scroll.get("top"));
        elt.scrollLeft(scroll.get("left"));
    },

    async load_doc(reload) {
        const url_to_pdf =
            raw_url(this.props.project_id, this.props.path) +
            "?param=" +
            reload;
        try {
            const doc = await getDocument(url_to_pdf);
            if (!this.mounted) return;
            this.setState({ doc: doc, loaded: true });
        } catch (err) {
            this.props.actions.set_error(`error loading PDF -- ${err}`);
        }
    },

    componentWillReceiveProps(next_props) {
        if (this.props.reload != next_props.reload)
            this.load_doc(next_props.reload);
    },

    componentWillUnmount() {
        this.mounted = false;
    },

    componentDidMount() {
        this.mounted = true;
        this.load_doc(this.props.reload);
    },

    render_pages() {
        window.doc = this.state.doc;
        const pages = [];
        for (let n = 1; n <= this.state.doc.numPages; n++) {
            pages.push(
                <Page
                    actions={this.props.actions}
                    doc={this.state.doc}
                    n={n}
                    key={n}
                    renderer={this.props.renderer}
                />
            );
        }
        return pages;
    },

    render() {
        if (!this.state.loaded) {
            return this.render_loading();
        }
        return (
            <div
                style={{
                    overflow: "scroll",
                    width: "100%",
                    zoom: this.props.font_size / 12
                }}
                onScroll={throttle(this.on_scroll, 250)}
                ref={"scroll"}
            >
                {this.render_pages()}
            </div>
        );
    }
});
